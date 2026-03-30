#!/bin/bash
# ============================================================
# 启动本地 MCP Bridge
# 用法: ./start-bridge.sh [允许的目录1,目录2,...]
# 示例: ./start-bridge.sh
#       ./start-bridge.sh ~/projects,~/Desktop/工作
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$SCRIPT_DIR/../local-bridge"

# 加载配置文件
ENV_FILE="$SCRIPT_DIR/../.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

build_default_roots() {
    local roots=()
    local candidate
    for candidate in "$HOME/Desktop" "$HOME/projects" "$HOME/Documents"; do
        [ -d "$candidate" ] && roots+=("$candidate")
    done

    if [ ${#roots[@]} -eq 0 ]; then
        roots+=("$HOME")
    fi

    local joined=""
    for candidate in "${roots[@]}"; do
        joined="${joined:+$joined,}$candidate"
    done
    printf '%s' "$joined"
}

# 默认允许的目录：当前用户的主要工作目录
DEFAULT_ROOTS="$(build_default_roots)"
ROOTS="${1:-${REMOTE_CC_ROOTS:-$DEFAULT_ROOTS}}"
PORT="${MCP_PORT:-${REMOTE_CC_PORT:-3100}}"
HOST="${MCP_HOST:-127.0.0.1}"

echo "========================================="
echo "  Remote CC - Local MCP Bridge"
echo "========================================="
echo "  Host:   $HOST"
echo "  Port:   $PORT"
echo "  Roots:  $ROOTS"
echo ""

# 检查端口是否被占用
if lsof -ti:"$PORT" > /dev/null 2>&1; then
    echo "Port $PORT is already in use:"
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN
    echo ""
    echo "Stop that process first, or set REMOTE_CC_PORT/MCP_PORT to a different port."
    exit 1
fi

cd "$BRIDGE_DIR"

# 安装依赖（如果需要）
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
    echo ""
fi

export MCP_ALLOWED_ROOTS="$ROOTS"
export MCP_PORT="$PORT"
export MCP_HOST="$HOST"

# ============================================================
# 自动检测 stdio MCP 并启动 SSE 代理
# ============================================================
STDIO_PROXY_BASE_PORT="${REMOTE_CC_STDIO_PROXY_BASE_PORT:-8800}"
STDIO_PROXY_PIDS=""

cleanup_proxies() {
    if [ -n "$STDIO_PROXY_PIDS" ]; then
        echo ""
        echo "Stopping stdio proxies..."
        for pid in $STDIO_PROXY_PIDS; do
            kill "$pid" 2>/dev/null
        done
    fi
    rm -f /tmp/remote-cc-stdio-proxies.json
}
trap cleanup_proxies EXIT

CLAUDE_JSON="$HOME/.claude.json"
if command -v jq &>/dev/null && [ -f "$CLAUDE_JSON" ]; then
    PROXY_PORT=$STDIO_PROXY_BASE_PORT
    PROXY_ENTRIES="[]"

    while IFS= read -r mcp_entry; do
        [ -z "$mcp_entry" ] && continue
        mcp_name=$(echo "$mcp_entry" | jq -r '.name')
        mcp_command=$(echo "$mcp_entry" | jq -r '.command')
        mcp_args=$(echo "$mcp_entry" | jq -r '.args // [] | join(" ")')

        echo "  Starting stdio proxy: $mcp_name → SSE on port $PROXY_PORT"
        echo "    Command: $mcp_command $mcp_args"

        npx tsx src/stdio-proxy.ts "$PROXY_PORT" $mcp_command $mcp_args &
        STDIO_PROXY_PIDS="$STDIO_PROXY_PIDS $!"

        PROXY_ENTRIES=$(echo "$PROXY_ENTRIES" | jq --arg name "$mcp_name" --arg url "http://127.0.0.1:$PROXY_PORT/sse" '. + [{"name": $name, "url": $url}]')
        PROXY_PORT=$((PROXY_PORT + 1))
    done < <(jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "stdio" or (.value.type | not)) | {name: .key, command: .value.command, args: .value.args} | @json' "$CLAUDE_JSON" 2>/dev/null)

    # Write proxy list for connect.sh to discover
    if [ "$PROXY_ENTRIES" != "[]" ]; then
        echo "$PROXY_ENTRIES" | jq -c '.[]' > /tmp/remote-cc-stdio-proxies.json
        echo ""
        echo "  Stdio proxies written to /tmp/remote-cc-stdio-proxies.json"
    fi
fi

echo ""
npx tsx src/index.ts
