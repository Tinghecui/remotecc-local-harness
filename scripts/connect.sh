#!/bin/bash
# ============================================================
# SSH 连接到云端并启动 Claude Code（使用持久化隧道）
# 用法: ./connect.sh [SSH_HOST] [LOCAL_WORKDIR]
# 示例: ./connect.sh
#       ./connect.sh root@1.2.3.4
#       ./connect.sh root@my-server ~/my-project
# 不指定 LOCAL_WORKDIR 时默认使用当前目录 (pwd)
#
# 前置条件: 先运行 start-bridge.sh 和 start-tunnel.sh
# ============================================================

# 加载配置文件
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# ── 参数解析：positional 参数 + Claude 透传参数 ──
POSITIONAL_ARGS=()
CLAUDE_EXTRA_ARGS=()

for _arg in "$@"; do
    case "$_arg" in
        --dangerously-skip-permissions|--verbose|--debug)
            CLAUDE_EXTRA_ARGS+=("$_arg")
            ;;
        --*)
            # 其他 -- 参数也透传给 claude
            CLAUDE_EXTRA_ARGS+=("$_arg")
            ;;
        *)
            POSITIONAL_ARGS+=("$_arg")
            ;;
    esac
done

CLOUD_HOST="${POSITIONAL_ARGS[0]:-${REMOTE_CC_HOST:-}}"
LOCAL_WORKDIR="${POSITIONAL_ARGS[1]:-$(pwd)}"
SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
SSH_KEY="${REMOTE_CC_SSH_KEY:-}"
TUNNEL_STATE_FILE="${REMOTE_CC_TUNNEL_STATE_FILE:-/tmp/remote-cc-tunnel.json}"
SSH_CONTROL_PATH="/tmp/remote-cc-ssh-$$-%r@%h:%p"
SSH_BASE_ARGS=(-p "$SSH_PORT" -o "ControlMaster=auto" -o "ControlPath=$SSH_CONTROL_PATH" -o "ControlPersist=60")
SCP_BASE_ARGS=(-P "$SSH_PORT" -o "ControlMaster=auto" -o "ControlPath=$SSH_CONTROL_PATH" -o "ControlPersist=60")
if [ -n "$SSH_KEY" ]; then
    SSH_BASE_ARGS+=(-i "$SSH_KEY")
    SCP_BASE_ARGS+=(-i "$SSH_KEY")
fi

ssh_remote() {
    local attempt=1
    local max_attempts=3
    local rc

    while [ "$attempt" -le "$max_attempts" ]; do
        ssh "${SSH_BASE_ARGS[@]}" "$CLOUD_HOST" "$@"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    return "$rc"
}

scp_remote() {
    local attempt=1
    local max_attempts=3
    local rc

    while [ "$attempt" -le "$max_attempts" ]; do
        scp -q "${SCP_BASE_ARGS[@]}" "$@"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    return "$rc"
}

if [ -z "$CLOUD_HOST" ]; then
    echo "Error: SSH host not specified."
    echo "Usage: ./scripts/connect.sh <SSH_USER@HOST> [LOCAL_WORKDIR]"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

# ── 检查持久化隧道 ──
if [ ! -f "$TUNNEL_STATE_FILE" ]; then
    echo "ERROR: Tunnel not running. Start it first:"
    echo "  ./scripts/start-tunnel.sh"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install it: brew install jq"
    exit 1
fi

TUNNEL_PID=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
if [ -z "$TUNNEL_PID" ] || ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "ERROR: Tunnel process (PID ${TUNNEL_PID:-unknown}) is dead. Restart it:"
    echo "  ./scripts/start-tunnel.sh"
    rm -f "$TUNNEL_STATE_FILE"
    exit 1
fi

# 从状态文件读取端口映射
REMOTE_BRIDGE_PORT=$(jq -r '.tunnels["local-bridge"].remote_port' "$TUNNEL_STATE_FILE")
if [ -z "$REMOTE_BRIDGE_PORT" ] || [ "$REMOTE_BRIDGE_PORT" = "null" ]; then
    echo "ERROR: Cannot read bridge port from tunnel state file."
    exit 1
fi

# 从状态文件构建 SSE MCP 列表（排除 local-bridge）
REMOTE_SSE_MCP_LIST=""
while IFS= read -r mcp_entry; do
    [ -z "$mcp_entry" ] && continue
    if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
        REMOTE_SSE_MCP_LIST="$REMOTE_SSE_MCP_LIST
$mcp_entry"
    else
        REMOTE_SSE_MCP_LIST="$mcp_entry"
    fi
done < <(jq -c '.tunnels | to_entries[] | select(.key != "local-bridge") | {name: .key, url: ("http://127.0.0.1:" + (.value.remote_port|tostring) + "/sse")}' "$TUNNEL_STATE_FILE")

slugify() {
    local value="$1"
    value=$(printf '%s' "$value" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')
    if [ -z "$value" ]; then
        value="project"
    fi
    printf '%s' "$value"
}

hash_string() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
    else
        echo "ERROR: Need shasum, sha256sum, or openssl to derive workspace identity." >&2
        exit 1
    fi
}

remote_stage_path() {
    printf '%s/%s' "$REMOTE_SESSION_DIR" "$1"
}

upload_file_if_exists() {
    local src="$1"
    local dest_name="$2"
    local label="$3"

    if [ -f "$src" ]; then
        [ -n "$label" ] && echo "  $label"
        scp_remote "$src" "$CLOUD_HOST:$(remote_stage_path "$dest_name")"
    fi
}

upload_dir_if_exists() {
    local src="$1"
    local dest_name="$2"
    local label="$3"
    local stage_dir
    local had_entries=0
    local entry
    local base_name

    if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
        [ -n "$label" ] && echo "  $label"
        stage_dir=$(mktemp -d "/tmp/remote-cc-upload.XXXXXX")

        for entry in "$src"/*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue

            # 跳过 broken symlinks
            if [ -L "$entry" ] && [ ! -e "$entry" ]; then
                echo "  WARNING: Skipping broken symlink: $entry"
                continue
            fi

            base_name="$(basename "$entry")"
            cp -R -L "$entry" "$stage_dir/$base_name"
            had_entries=1
        done

        if [ "$had_entries" -eq 1 ]; then
            ssh "${SSH_BASE_ARGS[@]}" "$CLOUD_HOST" "mkdir -p '$(remote_stage_path "$dest_name")'"
            scp_remote -r "$stage_dir"/* "$CLOUD_HOST:$(remote_stage_path "$dest_name")/"
        fi

        rm -rf "$stage_dir"
    fi
}

SESSION_ID="${REMOTE_CC_SESSION_ID:-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM}"
PROJECT_SLUG="$(slugify "$(basename "$LOCAL_WORKDIR")")"
PROJECT_HASH="$(hash_string "$LOCAL_WORKDIR" | cut -c1-12)"
WORKSPACE_MODE="${REMOTE_CC_WORKSPACE_MODE:-project}"
REMOTE_SESSION_DIR="/tmp/remote-cc-sessions/$SESSION_ID"
LOCAL_WORKDIR_B64=$(printf '%s' "$LOCAL_WORKDIR" | base64 | tr -d '\n')

resolve_remote_workspace_name() {
    case "$WORKSPACE_MODE" in
        session|isolated)
            printf '%s-%s' "$PROJECT_SLUG" "$SESSION_ID"
            return 0
            ;;
        project|stable)
            ;;
        *)
            echo "Error: REMOTE_CC_WORKSPACE_MODE must be 'project' or 'session'." >&2
            exit 1
            ;;
    esac

    ssh_remote "
        command -v python3 >/dev/null 2>&1 || {
            printf '%s\n' '$PROJECT_SLUG-$PROJECT_HASH'
            exit 0
        }
        python3 - <<'PY'
import base64
import glob
import os

local_dir = base64.b64decode('$LOCAL_WORKDIR_B64').decode('utf-8')
project_slug = '$PROJECT_SLUG'
project_hash = '$PROJECT_HASH'
workspace_root = os.path.expanduser('~/workspace')
stable_name = f'{project_slug}-{project_hash}'
stable_path = os.path.join(workspace_root, stable_name)

if os.path.isdir(stable_path):
    print(stable_name)
    raise SystemExit

matches = []
for path in glob.glob(os.path.join(workspace_root, '*')):
    if not os.path.isdir(path):
        continue
    marker_path = os.path.join(path, '.remote-cc-local-dir')
    try:
        if os.path.isfile(marker_path):
            with open(marker_path, encoding='utf-8') as handle:
                if handle.read().strip() == local_dir:
                    matches.append((os.path.getmtime(path), os.path.basename(path)))
    except OSError:
        continue

def rename_to_stable(best):
    # Rename workspace and its Claude project dir to the stable name.
    if best == stable_name:
        return
    old_path = os.path.join(workspace_root, best)
    new_path = os.path.join(workspace_root, stable_name)
    if os.path.exists(new_path):
        return
    os.rename(old_path, new_path)
    projects_dir = os.path.expanduser('~/.claude/projects')
    old_key = '-root-workspace-' + best
    new_key = '-root-workspace-' + stable_name
    old_proj = os.path.join(projects_dir, old_key)
    new_proj = os.path.join(projects_dir, new_key)
    if os.path.isdir(old_proj) and not os.path.isdir(new_proj):
        os.rename(old_proj, new_proj)

if matches:
    matches.sort()
    best = matches[-1][1]
    rename_to_stable(best)
    print(stable_name)
    raise SystemExit

legacy = []
prefix = project_slug + '-'
for path in glob.glob(os.path.join(workspace_root, prefix + '*')):
    if os.path.isdir(path):
        legacy.append((os.path.getmtime(path), os.path.basename(path)))

if legacy:
    legacy.sort()
    best = legacy[-1][1]
    rename_to_stable(best)
    print(stable_name)
else:
    print(stable_name)
PY
    "
}

WORKSPACE_NAME="$(resolve_remote_workspace_name)"
REMOTE_WORKSPACE="~/workspace/$WORKSPACE_NAME"

echo "========================================="
echo "  Remote CC - Connect"
echo "========================================="
echo "  Cloud:            $CLOUD_HOST"
echo "  Local Workdir:    $LOCAL_WORKDIR"
echo "  Workspace Mode:   $WORKSPACE_MODE"
echo "  Session:          $SESSION_ID"
echo "  Remote Workspace: $REMOTE_WORKSPACE"
echo "  Tunnel PID:       $TUNNEL_PID"
echo "  Remote Bridge:    localhost:$REMOTE_BRIDGE_PORT"

# 显示 MCP 隧道信息
if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
    echo "  MCP tunnels:"
    while IFS= read -r _entry; do
        [ -z "$_entry" ] && continue
        _name=$(echo "$_entry" | jq -r '.name')
        _url=$(echo "$_entry" | jq -r '.url')
        echo "    $_name → $_url"
    done <<< "$REMOTE_SSE_MCP_LIST"
fi
echo ""

# 提醒已有会话
EXISTING_SESSIONS=$(ps -axo pid=,command= | awk -v host="$CLOUD_HOST" '
    index($0, "ssh ") && index($0, host) && index($0, "/opt/remote-cc/prepare-session.sh") {
        pid = $1
        $1 = ""
        sub(/^ +/, "", $0)
        print pid "\t" $0
    }
')
if [ -n "$EXISTING_SESSIONS" ]; then
    echo "  Note: Found existing Remote CC session(s) for $CLOUD_HOST."
    echo "        All sessions share the same persistent tunnel."
    echo ""
fi

echo "Connecting... (Ctrl+D or /exit to quit)"
echo ""

# 准备云端会话暂存目录（root 创建，chown 给 cc 用户）
ssh_remote "rm -rf '$REMOTE_SESSION_DIR' && mkdir -p '$REMOTE_SESSION_DIR' && chown cc:cc '$REMOTE_SESSION_DIR'" || exit 1

# 上传本地 CLAUDE.md 文件（用户级 + 项目级）
upload_file_if_exists "$HOME/.claude/CLAUDE.md" "local-claude-user.md" "Uploading user-level CLAUDE.md..."
upload_file_if_exists "$LOCAL_WORKDIR/CLAUDE.md" "local-claude-project.md" "Uploading project-level CLAUDE.md..."

# 上传配置文件（settings、skills、commands）
echo "  Syncing config..."
upload_file_if_exists "$HOME/.claude/settings.json" "local-settings-user.json" ""
upload_file_if_exists "$HOME/.claude/settings.local.json" "local-settings-local-user.json" ""
upload_dir_if_exists "$HOME/.claude/skills" "local-skills-user" ""
upload_dir_if_exists "$HOME/.claude/commands" "local-commands-user" ""
upload_file_if_exists "$LOCAL_WORKDIR/.claude/settings.json" "local-settings-project.json" ""
upload_file_if_exists "$LOCAL_WORKDIR/.claude/settings.local.json" "local-settings-local-project.json" ""
upload_dir_if_exists "$LOCAL_WORKDIR/.claude/skills" "local-skills-project" ""
upload_dir_if_exists "$LOCAL_WORKDIR/.claude/commands" "local-commands-project" ""
upload_dir_if_exists "$HOME/.claude/agents" "local-agents-user" ""
upload_dir_if_exists "$LOCAL_WORKDIR/.claude/agents" "local-agents-project" ""

# 上传 SSE MCP 列表
if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
    printf '%s\n' "$REMOTE_SSE_MCP_LIST" | ssh_remote "cat > '$(remote_stage_path "local-sse-mcps.json")'"
    echo "  Project MCP list: uploaded"
fi

# SSH 连接启动 claude（不再需要 -R 隧道参数）
MAX_RETRIES=5
RETRY_DELAY=3

# 构建 Claude 启动命令（含透传参数）
CLAUDE_CMD="claude"
if [ ${#CLAUDE_EXTRA_ARGS[@]} -gt 0 ]; then
    for _carg in "${CLAUDE_EXTRA_ARGS[@]}"; do
        CLAUDE_CMD="$CLAUDE_CMD $_carg"
    done
fi

# 上传的文件 owner 是 root，需要 chown 给 cc 用户
# 然后以 cc 用户运行 prepare-session + claude（避免 root 限制）
REMOTE_CMD="chown -R cc:cc '$REMOTE_SESSION_DIR' && su - cc -c 'export PATH=\$HOME/.local/bin:\$PATH && export BRIDGE_PORT=\"$REMOTE_BRIDGE_PORT\" && export REMOTE_CC_LOCAL_DIR=\"\$(printf \"%s\" \"$LOCAL_WORKDIR_B64\" | base64 -d)\" && export REMOTE_CC_SESSION_ID=\"$SESSION_ID\" && export REMOTE_CC_SESSION_TMP=\"$REMOTE_SESSION_DIR\" && export REMOTE_CC_WORKSPACE_NAME=\"$WORKSPACE_NAME\" && /opt/remote-cc/prepare-session.sh && cd ~/workspace/$WORKSPACE_NAME && $CLAUDE_CMD'"

for _attempt in $(seq 1 $MAX_RETRIES); do
    ssh -t \
        "${SSH_BASE_ARGS[@]}" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        "$CLOUD_HOST" \
        "$REMOTE_CMD"

    EXIT_CODE=$?
    # Exit code 0 = normal exit (user typed /exit or Ctrl+D)
    [ $EXIT_CODE -eq 0 ] && break
    # Exit code 130 = Ctrl+C
    [ $EXIT_CODE -eq 130 ] && break

    echo ""
    echo "Connection lost (exit code $EXIT_CODE). Retry $_attempt/$MAX_RETRIES in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
    RETRY_DELAY=$((RETRY_DELAY * 2))
done
