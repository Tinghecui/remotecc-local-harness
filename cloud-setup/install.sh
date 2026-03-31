#!/bin/bash
set -e

# ============================================================
# Remote CC - 云端一键安装脚本
# 用法: ./install.sh <SSH_USER@HOST> [MCP_SSE_URL]
# 示例: ./install.sh root@99.173.22.106
#       ./install.sh root@99.173.22.106 http://127.0.0.1:3100/sse
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_HOST="${1:?Usage: ./install.sh <SSH_USER@HOST> [MCP_SSE_URL]}"
MCP_SSE_URL="${2:-http://127.0.0.1:3100/sse}"

echo "========================================="
echo "  Remote CC - Cloud Deploy"
echo "========================================="
echo "  Target:   $REMOTE_HOST"
echo "  MCP URL:  $MCP_SSE_URL"
echo ""

# ---- 上传文件 ----
echo "[1/4] Uploading files..."
ssh "$REMOTE_HOST" "mkdir -p /tmp/remote-cc-setup"
scp -r "$SCRIPT_DIR/hooks" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp -r "$SCRIPT_DIR/claude-config" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp "$SCRIPT_DIR/prepare-session.sh" "$REMOTE_HOST:/tmp/remote-cc-setup/"
scp "$SCRIPT_DIR/memory-sync.sh" "$REMOTE_HOST:/tmp/remote-cc-setup/"

# ---- 远程安装 ----
echo "[2/4] Installing on remote..."
ssh "$REMOTE_HOST" bash << 'INSTALL_EOF'
set -e

# 系统依赖
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl git jq 2>/dev/null

# 创建非 root 用户（Claude Code 禁止 root 使用 --dangerously-skip-permissions）
if ! id cc &>/dev/null; then
    useradd -m -s /bin/bash cc
    echo "  User cc: created"
else
    echo "  User cc: exists"
fi

# 以 cc 用户安装 Claude Code
if ! su - cc -c 'command -v claude &>/dev/null || test -f ~/.local/bin/claude' 2>/dev/null; then
    echo "  Installing Claude Code for cc user..."
    su - cc -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1
    su - cc -c 'echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'
else
    echo "  Claude Code already installed for cc user"
fi

echo "  Claude Code: $(su - cc -c '~/.local/bin/claude --version 2>/dev/null || claude --version 2>/dev/null')"
INSTALL_EOF

# ---- 配置 ----
echo "[3/4] Configuring..."
ssh "$REMOTE_HOST" bash << CONF_EOF
set -e

# Hook 脚本 + prepare-session（全局目录，root 部署）
mkdir -p /opt/remote-cc/hooks
cp /tmp/remote-cc-setup/hooks/block-builtin.sh /opt/remote-cc/hooks/
chmod +x /opt/remote-cc/hooks/block-builtin.sh
cp /tmp/remote-cc-setup/prepare-session.sh /opt/remote-cc/
chmod +x /opt/remote-cc/prepare-session.sh
cp /tmp/remote-cc-setup/memory-sync.sh /opt/remote-cc/
chmod +x /opt/remote-cc/memory-sync.sh

# Claude Code settings → cc 用户目录
CC_HOME=\$(eval echo ~cc)
mkdir -p "\$CC_HOME/.claude"
cp /tmp/remote-cc-setup/claude-config/settings.json "\$CC_HOME/.claude/settings.json"

# MCP server → cc 用户
su - cc -c 'export PATH="\$HOME/.local/bin:\$PATH" && claude mcp remove local-bridge 2>/dev/null || true && claude mcp add -t sse -s user -- local-bridge $MCP_SSE_URL' 2>&1

# workspace → cc 用户目录
mkdir -p "\$CC_HOME/workspace"
chown -R cc:cc "\$CC_HOME/.claude" "\$CC_HOME/workspace"

# 清理
rm -rf /tmp/remote-cc-setup
CONF_EOF

# ---- 验证 ----
echo "[4/4] Verifying..."
ssh "$REMOTE_HOST" bash << 'VERIFY_EOF'
CC_HOME=$(eval echo ~cc)
echo "  Claude:   $(su - cc -c '~/.local/bin/claude --version 2>/dev/null || claude --version 2>/dev/null')"
echo "  Hook:     $(test -x /opt/remote-cc/hooks/block-builtin.sh && echo 'OK' || echo 'MISSING')"
echo "  Settings: $(test -f "$CC_HOME/.claude/settings.json" && echo 'OK' || echo 'MISSING')"
echo "  MCP:"
su - cc -c 'export PATH="$HOME/.local/bin:$PATH" && claude mcp list 2>&1' | grep -E "local-bridge|Status" || true
VERIFY_EOF

echo ""
echo "========================================="
echo "  Deploy Complete!"
echo "========================================="
echo ""
echo "  Usage:"
echo "    1. Start local bridge:  ./scripts/start-bridge.sh"
echo "    2. Connect to cloud:    ./scripts/connect.sh $REMOTE_HOST"
echo ""
