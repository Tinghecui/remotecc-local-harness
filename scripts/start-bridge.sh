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

# 默认允许的目录：当前用户的主要工作目录
DEFAULT_ROOTS="$HOME/Desktop,$HOME/projects,$HOME/Documents"
ROOTS="${1:-${REMOTE_CC_ROOTS:-$DEFAULT_ROOTS}}"
PORT="${MCP_PORT:-${REMOTE_CC_PORT:-3100}}"

echo "========================================="
echo "  Remote CC - Local MCP Bridge"
echo "========================================="
echo "  Port:   $PORT"
echo "  Roots:  $ROOTS"
echo ""

# 检查端口是否被占用
if lsof -ti:"$PORT" > /dev/null 2>&1; then
    echo "Port $PORT is in use. Killing existing process..."
    lsof -ti:"$PORT" | xargs kill -9 2>/dev/null
    sleep 1
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

exec npx tsx src/index.ts
