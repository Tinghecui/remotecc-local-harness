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

if [ -z "$CLOUD_HOST" ]; then
    echo "Error: SSH host not specified."
    echo "Usage: ./scripts/connect.sh <SSH_USER@HOST> [LOCAL_BRIDGE_PORT] [LOCAL_WORKDIR]"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

REMOTE_USER="${CLOUD_HOST%@*}"
if [ "$REMOTE_USER" = "$CLOUD_HOST" ]; then
    REMOTE_USER=""
fi

if [ "$REMOTE_USER" = "root" ] && [ ${#CLAUDE_EXTRA_ARGS[@]} -gt 0 ]; then
    FILTERED_CLAUDE_ARGS=()
    for _carg in "${CLAUDE_EXTRA_ARGS[@]}"; do
        if [ "$_carg" = "--dangerously-skip-permissions" ]; then
            echo "WARNING: Ignoring --dangerously-skip-permissions for root SSH sessions."
            continue
        fi
        FILTERED_CLAUDE_ARGS+=("$_carg")
    done
    CLAUDE_EXTRA_ARGS=("${FILTERED_CLAUDE_ARGS[@]}")
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

        ssh -o ConnectTimeout=5 -p "$SSH_PORT" "$CLOUD_HOST" "
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
        scp -q -P "$SSH_PORT" "$src" "$CLOUD_HOST:$(remote_stage_path "$dest_name")"
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

            if [ -L "$entry" ] && [ ! -e "$entry" ]; then
                echo "  WARNING: Skipping broken symlink: $entry"
                continue
            fi

            base_name="$(basename "$entry")"
            cp -R -L "$entry" "$stage_dir/$base_name"
            had_entries=1
        done

        if [ "$had_entries" -eq 1 ]; then
            scp -q -P "$SSH_PORT" -r "$stage_dir" "$CLOUD_HOST:$(remote_stage_path "$dest_name")"
        fi

        rm -rf "$stage_dir"
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
WORKSPACE_NAME="${PROJECT_SLUG}-${SESSION_ID}"
REMOTE_SESSION_DIR="/tmp/remote-cc-sessions/$SESSION_ID"
REMOTE_WORKSPACE="~/workspace/$WORKSPACE_NAME"

echo "========================================="
echo "  Remote CC - Connect"
echo "========================================="
echo "  Cloud:            $CLOUD_HOST"
echo "  Local Bridge:     localhost:$BRIDGE_PORT"
echo "  Local Workdir:    $LOCAL_WORKDIR"
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
    echo "        This session will use isolated remote ports and workspace."
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

LOCAL_WORKDIR_B64=$(printf '%s' "$LOCAL_WORKDIR" | base64 | tr -d '\n')

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

# 准备云端会话暂存目录
ssh -p "$SSH_PORT" "$CLOUD_HOST" "rm -rf '$REMOTE_SESSION_DIR' && mkdir -p '$REMOTE_SESSION_DIR'" || exit 1

# 上传本地 CLAUDE.md 文件（用户级 + 项目级）
upload_file_if_exists "$HOME/.claude/CLAUDE.md" "local-claude-user.md" "Uploading user-level CLAUDE.md..."
upload_file_if_exists "$LOCAL_WORKDIR/CLAUDE.md" "local-claude-project.md" "Uploading project-level CLAUDE.md..."

# 上传配置文件（settings、commands）
echo "  Syncing config..."
upload_file_if_exists "$HOME/.claude/settings.json" "local-settings-user.json" ""
upload_file_if_exists "$HOME/.claude/settings.local.json" "local-settings-local-user.json" ""
upload_dir_if_exists "$HOME/.claude/commands" "local-commands-user" ""
upload_file_if_exists "$LOCAL_WORKDIR/.claude/settings.json" "local-settings-project.json" ""
upload_file_if_exists "$LOCAL_WORKDIR/.claude/settings.local.json" "local-settings-local-project.json" ""
upload_dir_if_exists "$LOCAL_WORKDIR/.claude/commands" "local-commands-project" ""

# 上传 skills + agents（tar 管道，排除非必需大文件 + resolve symlinks）
# 编辑此 blacklist 可控制哪些 skills 不同步到云端
SKILLS_BLACKLIST="last30days adapt animate arrange bolder clarify colorize critique delight distill extract normalize onboard optimize overdrive polish quieter typeset teach-impeccable buying-signals-6 campaign-sending clay-buying-signals-5 clay-enrichment-9step coldiq-messaging-templates email-generation email-prompt-building email-response-simulation email-verification hypothesis-building inbound-triggers-30 inbox-reply lead-sources-guide linkedin-limits-warmup list-segmentation market-research outbound-triggers-6 outreach-4-categories personalization-6-buckets personalization-playbooks sdr-master-prompts ai-personalization-prompts gtm-plays-11"

upload_dir_tar() {
    local src="$1"
    local dest_name="$2"
    local label="$3"
    local blacklist="${4:-}"

    if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
        return
    fi

    [ -n "$label" ] && echo "  $label"
    local stage_path
    stage_path="$(remote_stage_path "$dest_name")"
    ssh -p "$SSH_PORT" "$CLOUD_HOST" "mkdir -p '$stage_path'"

    # 构建 tar exclude 参数
    local TAR_EXCLUDES=(
        --exclude='.git'
        --exclude='assets'
        --exclude='vendor'
        --exclude='docs'
        --exclude='tests'
        --exclude='scripts'
        --exclude='node_modules'
        --exclude='plans'
        --exclude='*.png'
        --exclude='*.jpg'
        --exclude='*.gif'
        --exclude='*.svg'
        --exclude='CHANGELOG.md'
        --exclude='README.md'
    )

    # 加入 blacklist 排除
    if [ -n "$blacklist" ]; then
        for item in $blacklist; do
            TAR_EXCLUDES+=(--exclude="./$item")
        done
    fi

    tar cf - -L "${TAR_EXCLUDES[@]}" -C "$src" . 2>/dev/null \
        | ssh -p "$SSH_PORT" "$CLOUD_HOST" "tar xf - -C '$stage_path'"
}

upload_dir_tar "$HOME/.claude/skills" "local-skills-user" \
    "Syncing user skills (tar)..." "$SKILLS_BLACKLIST"
upload_dir_tar "$HOME/.claude/agents" "local-agents-user" \
    "Syncing user agents (tar)..."
upload_dir_tar "$LOCAL_WORKDIR/.claude/skills" "local-skills-project" ""
upload_dir_tar "$LOCAL_WORKDIR/.claude/agents" "local-agents-project" ""

# 上传本会话专属的 SSE MCP 列表
if [ -n "$REMOTE_SSE_MCP_LIST" ]; then
    REMOTE_MCP_STAGE_PATH="$(remote_stage_path "local-sse-mcps.json")"
    printf '%s\n' "$REMOTE_SSE_MCP_LIST" | ssh -p "$SSH_PORT" "$CLOUD_HOST" "cat > '$REMOTE_MCP_STAGE_PATH'"
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

REMOTE_CMD="export PATH=\$HOME/.local/bin:\$PATH && claude mcp remove local-bridge >/dev/null 2>&1 || true && export BRIDGE_PORT='$REMOTE_BRIDGE_PORT' && export REMOTE_CC_LOCAL_DIR=\$(printf '%s' '$LOCAL_WORKDIR_B64' | base64 -d) && export REMOTE_CC_SESSION_ID='$SESSION_ID' && export REMOTE_CC_SESSION_TMP='$REMOTE_SESSION_DIR' && export REMOTE_CC_WORKSPACE_NAME='$WORKSPACE_NAME' && /opt/remote-cc/prepare-session.sh && cd \"\$HOME/workspace/$WORKSPACE_NAME\" && $CLAUDE_CMD"

for _attempt in $(seq 1 $MAX_RETRIES); do
    ssh -t \
        -p "$SSH_PORT" \
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
