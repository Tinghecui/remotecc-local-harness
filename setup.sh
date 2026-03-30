#!/bin/bash
set -e

# ============================================================
# Remote CC - 一键部署
# 在本地运行此脚本，自动完成：
#   1. 安装本地 MCP Bridge 依赖
#   2. 部署云端 Claude Code + Hook + MCP 配置
#   3. 验证完整链路
#
# 用法: ./setup.sh <SSH_USER@HOST>
# 示例: ./setup.sh root@99.173.22.106
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# 加载配置文件
ENV_FILE="$SCRIPT_DIR/.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

REMOTE_HOST="${1:-${REMOTE_CC_HOST:-}}"
if [ -z "$REMOTE_HOST" ]; then
    echo "Error: SSH host not specified."
    echo "Usage: ./setup.sh <SSH_USER@HOST>"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi
BRIDGE_PORT="${BRIDGE_PORT:-${REMOTE_CC_PORT:-3100}}"
VERIFY_ROOTS="${REMOTE_CC_ROOTS:-$(build_default_roots)}"

echo "╔══════════════════════════════════════════════════╗"
echo "║  Remote CC - One-Click Setup                     ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Target:  ${REMOTE_HOST}$(printf '%*s' $((36 - ${#REMOTE_HOST})) '')║"
echo "║  Bridge:  localhost:${BRIDGE_PORT}$(printf '%*s' $((28 - ${#BRIDGE_PORT})) '')║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ===== Step 1: 检查前置条件 =====
echo "[1/5] Checking prerequisites..."

# 检查 Node.js
if ! command -v node &> /dev/null; then
    echo "  ERROR: Node.js not found. Install it first: https://nodejs.org"
    exit 1
fi
echo "  Node.js: $(node -v)"

# 检查 SSH 连接
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "echo ok" > /dev/null 2>&1; then
    echo "  ERROR: Cannot SSH to $REMOTE_HOST"
    echo "  Make sure you have SSH key access. Run: ssh-copy-id $REMOTE_HOST"
    exit 1
fi
echo "  SSH:     OK"

# ===== Step 2: 安装本地 Bridge 依赖 =====
echo ""
echo "[2/5] Installing local bridge dependencies..."
cd "$SCRIPT_DIR/local-bridge"
if [ ! -d "node_modules" ]; then
    npm install --silent 2>&1
    echo "  Dependencies installed"
else
    echo "  Dependencies already installed"
fi
cd "$SCRIPT_DIR"

# ===== Step 3: 部署云端 =====
echo ""
echo "[3/5] Deploying to cloud ($REMOTE_HOST)..."

# 上传文件
ssh "$REMOTE_HOST" "mkdir -p /tmp/remote-cc-setup"
scp -q -r "$SCRIPT_DIR/cloud-setup/hooks" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp -q -r "$SCRIPT_DIR/cloud-setup/claude-config" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp -q "$SCRIPT_DIR/cloud-setup/prepare-session.sh" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp -q "$SCRIPT_DIR/cloud-setup/memory-sync.sh" "$REMOTE_HOST:/tmp/remote-cc-setup/"
echo "  Files uploaded"

# 安装 Claude Code
ssh "$REMOTE_HOST" bash << 'REMOTE_INSTALL'
set -e
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl git jq 2>/dev/null

if ! command -v claude &> /dev/null && ! test -f ~/.local/bin/claude; then
    curl -fsSL https://claude.ai/install.sh | bash 2>&1
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
echo "  Claude Code: $(~/.local/bin/claude --version 2>/dev/null || claude --version 2>/dev/null)"
REMOTE_INSTALL

# 配置 Hook + MCP
ssh "$REMOTE_HOST" bash << REMOTE_CONFIG
set -e
export PATH="\$HOME/.local/bin:\$PATH"

# Hook + prepare-session
mkdir -p /opt/remote-cc/hooks
cp /tmp/remote-cc-setup/hooks/block-builtin.sh /opt/remote-cc/hooks/
chmod +x /opt/remote-cc/hooks/block-builtin.sh
cp /tmp/remote-cc-setup/prepare-session.sh /opt/remote-cc/
chmod +x /opt/remote-cc/prepare-session.sh
cp /tmp/remote-cc-setup/memory-sync.sh /opt/remote-cc/
chmod +x /opt/remote-cc/memory-sync.sh

# Settings
mkdir -p ~/.claude
cp /tmp/remote-cc-setup/claude-config/settings.json ~/.claude/settings.json

# MCP (SSE, no auth - secured by SSH tunnel)
claude mcp remove local-bridge 2>/dev/null || true
claude mcp add -t sse -s user -- local-bridge http://127.0.0.1:${BRIDGE_PORT}/sse 2>&1

# workspace（CLAUDE.md 由 prepare-session.sh 动态生成）
mkdir -p ~/workspace

# Cleanup
rm -rf /tmp/remote-cc-setup
REMOTE_CONFIG
echo "  Cloud configured"

# ===== Step 4: 快速验证 =====
echo ""
echo "[4/5] Verifying..."

# 启动本地 Bridge（后台临时验证）
MCP_ALLOWED_ROOTS="$VERIFY_ROOTS" \
MCP_HOST="127.0.0.1" \
MCP_PORT="$BRIDGE_PORT" \
npx tsx "$SCRIPT_DIR/local-bridge/src/index.ts" &
BRIDGE_PID=$!
sleep 3

# 通过 SSH 隧道验证连通性
HEALTH=$(ssh -R "$BRIDGE_PORT:localhost:$BRIDGE_PORT" "$REMOTE_HOST" \
  "curl -s http://127.0.0.1:$BRIDGE_PORT/health 2>/dev/null" || echo "FAILED")

kill $BRIDGE_PID 2>/dev/null
wait $BRIDGE_PID 2>/dev/null || true

if echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo "  Tunnel:  OK"
    echo "  Bridge:  OK"
else
    echo "  WARNING: Tunnel verification failed. This may be normal"
    echo "           if another process is using port $BRIDGE_PORT."
fi

# ===== Step 5: 完成 =====
echo ""
echo "[5/5] Done!"
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Setup Complete!                                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  Step 1: Start the bridge (keep running)         ║"
echo "║                                                  ║"
echo "║    ./scripts/start-bridge.sh                     ║"
echo "║                                                  ║"
echo "║  Step 2: Connect to cloud Claude Code            ║"
echo "║                                                  ║"
echo "║    ./scripts/connect.sh ${REMOTE_HOST}$(printf '%*s' $((21 - ${#REMOTE_HOST})) '')║"
echo "║                                                  ║"
echo "║  Open multiple terminals for parallel sessions.  ║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
