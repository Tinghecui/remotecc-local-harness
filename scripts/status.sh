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
if curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    HEALTH=$(curl -s "http://127.0.0.1:$BRIDGE_PORT/health")
    echo "  Status: RUNNING"
    echo "  Info:   $HEALTH"
else
    echo "  Status: NOT RUNNING"
    echo "  Start:  ./scripts/start-bridge.sh"
fi
echo ""

# 检查云端连通性
CLOUD_HOST="${1:-${REMOTE_CC_HOST:-}}"
SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
SSH_KEY="${REMOTE_CC_SSH_KEY:-}"
SSH_BASE_ARGS=(-p "$SSH_PORT")
if [ -n "$SSH_KEY" ]; then
    SSH_BASE_ARGS+=(-i "$SSH_KEY")
fi
if [ -z "$CLOUD_HOST" ]; then
    echo "Error: VPS host not specified."
    echo "Usage: ./scripts/status.sh <SSH_USER@HOST>"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

# README 中常用 bare IP；默认补成 root@HOST
if [[ "$CLOUD_HOST" != *@* ]]; then
    CLOUD_HOST="root@$CLOUD_HOST"
fi

echo "[Cloud Server: $CLOUD_HOST]"
if ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_BASE_ARGS[@]}" "$CLOUD_HOST" "echo ok" > /dev/null 2>&1; then
    echo "  SSH:    OK"
    CLAUDE_VERSION=$(ssh -o ConnectTimeout=10 "${SSH_BASE_ARGS[@]}" "$CLOUD_HOST" "export PATH=\$HOME/.local/bin:\$PATH && claude --version" 2>/dev/null)
    if [ -n "$CLAUDE_VERSION" ]; then
        echo "  Claude: $CLAUDE_VERSION"
    else
        echo "  Claude: NOT INSTALLED"
    fi
else
    echo "  SSH:    UNREACHABLE"
fi
echo ""
