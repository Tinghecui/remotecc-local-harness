#!/bin/bash
# 检查各组件状态

# 加载配置文件
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

echo "========================================="
echo "  Remote CC - Status Check"
echo "========================================="
echo ""

# 检查本地 MCP Bridge
echo "[Local MCP Bridge]"
BRIDGE_PORT="${REMOTE_CC_PORT:-${MCP_PORT:-3100}}"
if curl -s "http://localhost:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    HEALTH=$(curl -s "http://localhost:$BRIDGE_PORT/health")
    echo "  Status: RUNNING"
    echo "  Info:   $HEALTH"
else
    echo "  Status: NOT RUNNING"
    echo "  Start:  ./scripts/start-bridge.sh"
fi
echo ""

# 检查云端连通性
CLOUD_HOST="${1:-${REMOTE_CC_HOST:-}}"
if [ -z "$CLOUD_HOST" ]; then
    echo "Error: VPS host not specified."
    echo "Usage: ./scripts/status.sh <SSH_USER@HOST>"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi
# 从 user@host 中提取 host 部分用于 SSH
CLOUD_HOST_CLEAN="$CLOUD_HOST"
echo "[Cloud Server: $CLOUD_HOST]"
if ssh -o ConnectTimeout=3 -o BatchMode=yes "$CLOUD_HOST" "echo ok" > /dev/null 2>&1; then
    echo "  SSH:    OK"
    CLAUDE_OK=$(ssh -o ConnectTimeout=3 "$CLOUD_HOST" "command -v claude" 2>/dev/null)
    if [ -n "$CLAUDE_OK" ]; then
        echo "  Claude: INSTALLED"
    else
        echo "  Claude: NOT INSTALLED"
    fi
else
    echo "  SSH:    UNREACHABLE"
fi
echo ""

# 检查 Tailscale
echo "[Tailscale]"
if command -v tailscale &> /dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | head -1)
    if [ -n "$TS_STATUS" ]; then
        echo "  Status: CONNECTED"
        tailscale status 2>/dev/null | head -5
    else
        echo "  Status: INSTALLED but not connected"
        echo "  Run:    tailscale up"
    fi
else
    echo "  Status: NOT INSTALLED"
fi
echo ""
