#!/bin/bash
# ============================================================
# SSH 连接到云端并启动 Claude Code（自动建立反向隧道）
# 用法: ./connect.sh [SSH_HOST] [LOCAL_BRIDGE_PORT] [LOCAL_WORKDIR]
# 示例: ./connect.sh
#       ./connect.sh root@99.173.22.106
#       ./connect.sh root@my-server 3100 ~/my-project
# 不指定 LOCAL_WORKDIR 时默认使用当前目录 (pwd)
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
BRIDGE_PORT="${POSITIONAL_ARGS[1]:-${REMOTE_CC_PORT:-3100}}"
LOCAL_WORKDIR="${POSITIONAL_ARGS[2]:-$(pwd)}"
REMOTE_PORT_START="${REMOTE_CC_REMOTE_PORT_START:-43000}"
REMOTE_PORT_END="${REMOTE_CC_REMOTE_PORT_END:-48999}"
SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
SSH_KEY="${REMOTE_CC_SSH_KEY:-}"
SSH_BASE_ARGS=(-p "$SSH_PORT")
SCP_BASE_ARGS=(-P "$SSH_PORT")
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

ssh_remote_quick() {
    ssh -o ConnectTimeout=10 "${SSH_BASE_ARGS[@]}" "$CLOUD_HOST" "$@"
}

ssh_remote_quick_status() {
    local attempt=1
    local max_attempts=3
    local rc

    while [ "$attempt" -le "$max_attempts" ]; do
        ssh_remote_quick "$@"
        rc=$?
        case "$rc" in
            0|1)
                return "$rc"
                ;;
        esac

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
    echo "Usage: ./scripts/connect.sh <SSH_USER@HOST> [LOCAL_BRIDGE_PORT] [LOCAL_WORKDIR]"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

if [ "$REMOTE_PORT_START" -gt "$REMOTE_PORT_END" ] 2>/dev/null; then
    echo "Error: REMOTE_CC_REMOTE_PORT_START must be <= REMOTE_CC_REMOTE_PORT_END."
    exit 1
fi

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

extract_port_from_url() {
    printf '%s' "$1" | sed -n 's|.*://[^:/]*:\([0-9][0-9]*\).*|\1|p'
}

rewrite_url_port() {
    local url="$1"
    local new_port="$2"
    printf '%s' "$url" | sed -E "s#(https?://[^:/]+:)[0-9]+#\1${new_port}#"
}

REMOTE_PORTS_SEEN=""
allocate_remote_port() {
    local attempt=0
    local max_attempts=100
    local port
    local rc

    while [ "$attempt" -lt "$max_attempts" ]; do
        port=$((REMOTE_PORT_START + RANDOM % (REMOTE_PORT_END - REMOTE_PORT_START + 1)))
        attempt=$((attempt + 1))

        case "$REMOTE_PORTS_SEEN" in
            *":$port:"*) continue ;;
        esac

        ssh_remote_quick_status "
            PORT='$port'
            if (ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print \$4}' | grep -Eq '(^|[.:])'\$PORT'$'; then
                exit 0
            fi
            exit 1
        " >/dev/null 2>&1
        rc=$?

        if [ "$rc" -eq 0 ]; then
            continue
        fi

        if [ "$rc" -eq 1 ]; then
            REMOTE_PORTS_SEEN="${REMOTE_PORTS_SEEN}:$port:"
            printf '%s' "$port"
            return 0
        fi

        echo "ERROR: Failed to inspect remote ports on $CLOUD_HOST" >&2
        return 1
    done

    echo "ERROR: Could not allocate a free remote port after $max_attempts attempts." >&2
    return 1
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

    if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
        [ -n "$label" ] && echo "  $label"
        scp_remote -r "$src" "$CLOUD_HOST:$(remote_stage_path "$dest_name")"
    fi
}

SSH_FORWARD_ARGS=()
REMOTE_SSE_MCP_LIST=""
DISCOVERED_LOCAL_PORTS=":$BRIDGE_PORT:"

append_remote_mcp() {
    local name="$1"
    local url="$2"
    local entry

    if ! command -v jq >/dev/null 2>&1; then
        return
    fi

    entry=$(jq -cn --arg name "$name" --arg url "$url" '{name: $name, url: $url}')
    if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
        REMOTE_SSE_MCP_LIST="$REMOTE_SSE_MCP_LIST
$entry"
    else
        REMOTE_SSE_MCP_LIST="$entry"
    fi
}

add_mcp_forward() {
    local source_label="$1"
    local mcp_name="$2"
    local mcp_url="$3"
    local local_port
    local remote_port
    local remote_url

    local_port=$(extract_port_from_url "$mcp_url")
    if [ -z "$local_port" ]; then
        echo "  WARNING: Cannot extract port from $source_label '$mcp_name' URL: $mcp_url, skipping"
        return
    fi

    if [ "$local_port" = "$BRIDGE_PORT" ]; then
        return
    fi

    case "$DISCOVERED_LOCAL_PORTS" in
        *":$local_port:"*) return ;;
    esac
    DISCOVERED_LOCAL_PORTS="${DISCOVERED_LOCAL_PORTS}:$local_port:"

    remote_port=$(allocate_remote_port) || exit 1
    remote_url=$(rewrite_url_port "$mcp_url" "$remote_port")

    echo "  Found $source_label: $mcp_name → local $local_port / remote $remote_port"
    SSH_FORWARD_ARGS+=(-R "$remote_port:localhost:$local_port")
    append_remote_mcp "$mcp_name" "$remote_url"
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
echo "  Local Bridge:     localhost:$BRIDGE_PORT"
echo "  Local Workdir:    $LOCAL_WORKDIR"
echo "  Workspace Mode:   $WORKSPACE_MODE"
echo "  Session:          $SESSION_ID"
echo "  Remote Workspace: $REMOTE_WORKSPACE"
echo ""

# 提醒已有会话，但不阻止并行连接
EXISTING_TUNNELS=$(ps -axo pid=,command= | awk -v host="$CLOUD_HOST" '
    index($0, "ssh ") && index($0, host) && index($0, "/opt/remote-cc/prepare-session.sh") {
        pid = $1
        $1 = ""
        sub(/^ +/, "", $0)
        print pid "\t" $0
    }
')
if [ -n "$EXISTING_TUNNELS" ]; then
    echo "  Note: Found existing Remote CC session(s) for $CLOUD_HOST."
    echo "        This session will use isolated remote ports."
    echo ""
fi

# 检查本地 Bridge 是否在运行
if ! curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    echo "WARNING: Local MCP Bridge is not running on port $BRIDGE_PORT"
    echo "  Start it first:  ./scripts/start-bridge.sh"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

REMOTE_BRIDGE_PORT=$(allocate_remote_port) || exit 1
SSH_FORWARD_ARGS+=(-R "$REMOTE_BRIDGE_PORT:localhost:$BRIDGE_PORT")
echo "  Remote Bridge:    localhost:$REMOTE_BRIDGE_PORT → local:$BRIDGE_PORT"

# ============================================================
# 检测本地 SSE 类型 MCP 服务器，自动添加隧道
# ============================================================
if command -v jq >/dev/null 2>&1 && [ -f "$HOME/.claude.json" ]; then
    while IFS= read -r mcp_entry; do
        [ -z "$mcp_entry" ] && continue
        mcp_name=$(echo "$mcp_entry" | jq -r '.name')
        mcp_url=$(echo "$mcp_entry" | jq -r '.url')
        add_mcp_forward "SSE MCP" "$mcp_name" "$mcp_url"
    done < <(jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "sse") | {name: .key, url: .value.url} | @json' "$HOME/.claude.json" 2>/dev/null)
fi

# ============================================================
# 检测 stdio MCP 代理（由 start-bridge.sh 启动）
# ============================================================
STDIO_PROXIES_FILE="/tmp/remote-cc-stdio-proxies.json"
if [ -f "$STDIO_PROXIES_FILE" ]; then
    while IFS= read -r proxy_entry; do
        [ -z "$proxy_entry" ] && continue
        mcp_name=$(echo "$proxy_entry" | jq -r '.name')
        mcp_url=$(echo "$proxy_entry" | jq -r '.url')
        add_mcp_forward "stdio proxy" "$mcp_name" "$mcp_url"
    done < "$STDIO_PROXIES_FILE"
fi

echo ""
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

# 上传本会话专属的 SSE MCP 列表
if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
    printf '%s\n' "$REMOTE_SSE_MCP_LIST" | ssh_remote "cat > '$(remote_stage_path "local-sse-mcps.json")'"
    echo "  Project MCP list: uploaded"
fi

# SSH 反向隧道 + 启动 claude
# -t: 分配伪终端（claude 需要交互式终端）
# -R: 反向隧道，让云端 localhost:REMOTE_PORT 指向本地 localhost:LOCAL_PORT
# SSH with keepalive and auto-reconnect
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
        -o ExitOnForwardFailure=yes \
        "${SSH_FORWARD_ARGS[@]}" \
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
