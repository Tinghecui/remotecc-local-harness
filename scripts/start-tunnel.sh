#!/bin/bash
# ============================================================
# 持久化 SSH 反向隧道（固定端口，所有 Claude session 共享）
# 用法: ./start-tunnel.sh [SSH_HOST]
# 示例: ./start-tunnel.sh
#       ./start-tunnel.sh root@1.2.3.4
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

CLOUD_HOST="${1:-${REMOTE_CC_HOST:-}}"
BRIDGE_PORT="${REMOTE_CC_PORT:-3100}"
SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
SSH_KEY="${REMOTE_CC_SSH_KEY:-}"
TUNNEL_BRIDGE_PORT="${REMOTE_CC_TUNNEL_BRIDGE_PORT:-43100}"
TUNNEL_PROXY_BASE_PORT="${REMOTE_CC_TUNNEL_PROXY_BASE_PORT:-43800}"
TUNNEL_STATE_FILE="${REMOTE_CC_TUNNEL_STATE_FILE:-/tmp/remote-cc-tunnel.json}"

if [ -z "$CLOUD_HOST" ]; then
    echo "Error: SSH host not specified."
    echo "Usage: ./scripts/start-tunnel.sh [SSH_USER@HOST]"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

SSH_BASE_ARGS=(-p "$SSH_PORT" -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -o "ExitOnForwardFailure=yes")
if [ -n "$SSH_KEY" ]; then
    SSH_BASE_ARGS+=(-i "$SSH_KEY")
fi

# ── 检查是否已经在运行 ──
check_existing_tunnel() {
    if [ ! -f "$TUNNEL_STATE_FILE" ]; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    local pid
    pid=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
    if [ -z "$pid" ]; then
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    return 1
}

# ── 检查代理列表是否变化 ──
current_proxy_signature() {
    local sig=""
    sig="${sig}bridge:${BRIDGE_PORT}:${TUNNEL_BRIDGE_PORT}"

    if [ -f "/tmp/remote-cc-stdio-proxies.json" ]; then
        sig="${sig}|stdio:$(cat /tmp/remote-cc-stdio-proxies.json | sort)"
    fi

    if command -v jq &>/dev/null && [ -f "$HOME/.claude.json" ]; then
        local sse_mcps
        sse_mcps=$(jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "sse") | "\(.key):\(.value.url)"' "$HOME/.claude.json" 2>/dev/null | sort)
        if [ -n "$sse_mcps" ]; then
            sig="${sig}|sse:${sse_mcps}"
        fi
    fi

    printf '%s' "$sig" | shasum -a 256 2>/dev/null | awk '{print $1}' || printf '%s' "$sig" | sha256sum 2>/dev/null | awk '{print $1}' || printf '%s' "$sig"
}

if check_existing_tunnel; then
    old_sig=$(jq -r '.proxy_signature // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
    new_sig=$(current_proxy_signature)

    if [ "$old_sig" = "$new_sig" ]; then
        echo "Tunnel already running (PID $(jq -r '.pid' "$TUNNEL_STATE_FILE"))."
        echo ""
        echo "Port mappings:"
        jq -r '.tunnels | to_entries[] | "  \(.key): local:\(.value.local_port) → remote:\(.value.remote_port)"' "$TUNNEL_STATE_FILE"
        exit 0
    else
        echo "MCP configuration changed. Restarting tunnel..."
        old_pid=$(jq -r '.pid' "$TUNNEL_STATE_FILE")
        kill "$old_pid" 2>/dev/null
        sleep 1
        kill -9 "$old_pid" 2>/dev/null
        rm -f "$TUNNEL_STATE_FILE"
    fi
fi

# ── 构建隧道参数 ──
SSH_FORWARD_ARGS=()
TUNNELS_JSON="{}"

# Bridge 隧道（固定）
SSH_FORWARD_ARGS+=(-R "${TUNNEL_BRIDGE_PORT}:localhost:${BRIDGE_PORT}")
TUNNELS_JSON=$(echo "$TUNNELS_JSON" | jq --arg lp "$BRIDGE_PORT" --arg rp "$TUNNEL_BRIDGE_PORT" \
    '. + {"local-bridge": {"local_port": ($lp|tonumber), "remote_port": ($rp|tonumber)}}')

echo "========================================="
echo "  Remote CC - Persistent Tunnel"
echo "========================================="
echo "  Host:       $CLOUD_HOST"
echo "  Bridge:     local:$BRIDGE_PORT → remote:$TUNNEL_BRIDGE_PORT"

# Stdio MCP 代理
PROXY_INDEX=0
STDIO_PROXIES_FILE="/tmp/remote-cc-stdio-proxies.json"
if command -v jq &>/dev/null && [ -f "$STDIO_PROXIES_FILE" ]; then
    while IFS= read -r proxy_entry; do
        [ -z "$proxy_entry" ] && continue
        mcp_name=$(echo "$proxy_entry" | jq -r '.name')
        mcp_url=$(echo "$proxy_entry" | jq -r '.url')
        local_port=$(printf '%s' "$mcp_url" | sed -n 's|.*://[^:/]*:\([0-9][0-9]*\).*|\1|p')

        if [ -z "$local_port" ] || [ "$local_port" = "$BRIDGE_PORT" ]; then
            continue
        fi

        remote_port=$((TUNNEL_PROXY_BASE_PORT + PROXY_INDEX))
        SSH_FORWARD_ARGS+=(-R "${remote_port}:localhost:${local_port}")
        TUNNELS_JSON=$(echo "$TUNNELS_JSON" | jq --arg name "$mcp_name" --arg lp "$local_port" --arg rp "$remote_port" \
            '. + {($name): {"local_port": ($lp|tonumber), "remote_port": ($rp|tonumber)}}')
        echo "  $mcp_name:  local:$local_port → remote:$remote_port"
        PROXY_INDEX=$((PROXY_INDEX + 1))
    done < "$STDIO_PROXIES_FILE"
fi

# SSE MCP 服务器（从 ~/.claude.json）
DISCOVERED_LOCAL_PORTS=":$BRIDGE_PORT:"
if command -v jq &>/dev/null && [ -f "$HOME/.claude.json" ]; then
    while IFS= read -r mcp_entry; do
        [ -z "$mcp_entry" ] && continue
        mcp_name=$(echo "$mcp_entry" | jq -r '.name')
        mcp_url=$(echo "$mcp_entry" | jq -r '.url')
        local_port=$(printf '%s' "$mcp_url" | sed -n 's|.*://[^:/]*:\([0-9][0-9]*\).*|\1|p')

        if [ -z "$local_port" ]; then
            continue
        fi

        case "$DISCOVERED_LOCAL_PORTS" in
            *":$local_port:"*) continue ;;
        esac
        DISCOVERED_LOCAL_PORTS="${DISCOVERED_LOCAL_PORTS}:$local_port:"

        remote_port=$((TUNNEL_PROXY_BASE_PORT + PROXY_INDEX))
        SSH_FORWARD_ARGS+=(-R "${remote_port}:localhost:${local_port}")
        TUNNELS_JSON=$(echo "$TUNNELS_JSON" | jq --arg name "$mcp_name" --arg lp "$local_port" --arg rp "$remote_port" \
            '. + {($name): {"local_port": ($lp|tonumber), "remote_port": ($rp|tonumber)}}')
        echo "  $mcp_name:  local:$local_port → remote:$remote_port"
        PROXY_INDEX=$((PROXY_INDEX + 1))
    done < <(jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "sse") | {name: .key, url: .value.url} | @json' "$HOME/.claude.json" 2>/dev/null)
fi

echo ""

# ── 写入状态文件 ──
PROXY_SIG=$(current_proxy_signature)

write_state_file() {
    local pid="$1"
    jq -n \
        --arg pid "$pid" \
        --arg host "$CLOUD_HOST" \
        --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sig "$PROXY_SIG" \
        --argjson tunnels "$TUNNELS_JSON" \
        '{
            pid: ($pid|tonumber),
            host: $host,
            started_at: $started,
            proxy_signature: $sig,
            tunnels: $tunnels
        }' > "$TUNNEL_STATE_FILE"
}

# ── 清理函数 ──
SSH_PID=""
cleanup() {
    echo ""
    echo "Stopping tunnel..."
    if [ -n "$SSH_PID" ]; then
        kill "$SSH_PID" 2>/dev/null
        wait "$SSH_PID" 2>/dev/null
    fi
    rm -f "$TUNNEL_STATE_FILE"
    echo "Tunnel stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# ── 启动隧道 ──
echo "Starting tunnel... (Ctrl+C to stop)"
echo ""

if command -v autossh &>/dev/null; then
    echo "Using autossh for auto-reconnect."
    AUTOSSH_GATETIME=0 AUTOSSH_POLL=30 autossh -M 0 -N \
        "${SSH_BASE_ARGS[@]}" \
        "${SSH_FORWARD_ARGS[@]}" \
        "$CLOUD_HOST" &
    SSH_PID=$!
    write_state_file "$SSH_PID"
    echo "Tunnel established (PID $SSH_PID)."
    wait "$SSH_PID"
else
    RETRY_DELAY=3
    while true; do
        ssh -N \
            "${SSH_BASE_ARGS[@]}" \
            "${SSH_FORWARD_ARGS[@]}" \
            "$CLOUD_HOST" &
        SSH_PID=$!
        write_state_file "$SSH_PID"
        echo "Tunnel established (PID $SSH_PID)."

        wait "$SSH_PID"
        EXIT_CODE=$?

        # 正常退出（被 cleanup 杀掉）
        if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 143 ]; then
            break
        fi

        echo "Tunnel disconnected (exit $EXIT_CODE). Reconnecting in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        RETRY_DELAY=$((RETRY_DELAY * 2 > 30 ? 30 : RETRY_DELAY * 2))
    done
fi
