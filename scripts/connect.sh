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

# ── 增量同步：收集 → hash → 跳过或打包上传 ──
CONFIG_CACHE_DIR="/tmp/remote-cc-config-cache-${WORKSPACE_NAME}"
SYNC_STAGE=$(mktemp -d "/tmp/remote-cc-sync-stage.XXXXXX")

collect_file() {
    local src="$1" dest="$2"
    [ -f "$src" ] && cp "$src" "$SYNC_STAGE/$dest"
}

collect_dir() {
    local src="$1" dest="$2"
    if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
        mkdir -p "$SYNC_STAGE/$dest"
        for entry in "$src"/*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            # 跳过 broken symlinks
            if [ -L "$entry" ] && [ ! -e "$entry" ]; then continue; fi
            cp -R -L "$entry" "$SYNC_STAGE/$dest/"
        done
    fi
}

# 收集所有配置文件
collect_file "$HOME/.claude/CLAUDE.md" "local-claude-user.md"
collect_file "$LOCAL_WORKDIR/CLAUDE.md" "local-claude-project.md"
collect_file "$HOME/.claude/settings.json" "local-settings-user.json"
collect_file "$HOME/.claude/settings.local.json" "local-settings-local-user.json"
collect_dir  "$HOME/.claude/skills" "local-skills-user"
collect_dir  "$HOME/.claude/commands" "local-commands-user"
collect_dir  "$HOME/.claude/agents" "local-agents-user"
collect_file "$LOCAL_WORKDIR/.claude/settings.json" "local-settings-project.json"
collect_file "$LOCAL_WORKDIR/.claude/settings.local.json" "local-settings-local-project.json"
collect_dir  "$LOCAL_WORKDIR/.claude/skills" "local-skills-project"
collect_dir  "$LOCAL_WORKDIR/.claude/commands" "local-commands-project"
collect_dir  "$LOCAL_WORKDIR/.claude/agents" "local-agents-project"
if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
    printf '%s\n' "$REMOTE_SSE_MCP_LIST" > "$SYNC_STAGE/local-sse-mcps.json"
fi

# 计算内容 hash
SYNC_HASH_KEY=$(printf '%s-%s' "$CLOUD_HOST" "$LOCAL_WORKDIR" | shasum -a 256 2>/dev/null | cut -c1-16)
SYNC_MANIFEST="/tmp/remote-cc-sync-${SYNC_HASH_KEY}.manifest"
CURRENT_HASH=$(find "$SYNC_STAGE" -type f -exec shasum {} + 2>/dev/null | LC_ALL=C sort | shasum -a 256 | cut -c1-64)
CACHED_HASH=$(cat "$SYNC_MANIFEST" 2>/dev/null || echo "")

if [ "$CURRENT_HASH" = "$CACHED_HASH" ]; then
    # 配置未变 — 从云端持久缓存复制到本次会话目录（本地 cp，毫秒级）
    ssh_remote "if [ -d '$CONFIG_CACHE_DIR' ]; then cp -a '$CONFIG_CACHE_DIR'/. '$REMOTE_SESSION_DIR/' && chown -R cc:cc '$REMOTE_SESSION_DIR'; else mkdir -p '$CONFIG_CACHE_DIR'; fi"
    echo "  Config unchanged, using cloud cache"
else
    # 配置有变 — 打包一次上传（1 scp 替代 ~12 次）
    SYNC_TAR="${SYNC_STAGE}.tar.gz"
    tar czf "$SYNC_TAR" -C "$SYNC_STAGE" .
    SYNC_SIZE=$(du -sh "$SYNC_TAR" 2>/dev/null | cut -f1)
    scp_remote "$SYNC_TAR" "$CLOUD_HOST:${REMOTE_SESSION_DIR}/sync-bundle.tar.gz"
    ssh_remote "cd '$REMOTE_SESSION_DIR' && tar xzf sync-bundle.tar.gz && rm -f sync-bundle.tar.gz && rm -rf '$CONFIG_CACHE_DIR' && cp -a '$REMOTE_SESSION_DIR' '$CONFIG_CACHE_DIR' && chown -R cc:cc '$REMOTE_SESSION_DIR'"
    printf '%s' "$CURRENT_HASH" > "$SYNC_MANIFEST"
    echo "  Config synced (${SYNC_SIZE:-?} uploaded)"
    rm -f "$SYNC_TAR"
fi

rm -rf "$SYNC_STAGE"

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
