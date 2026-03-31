#!/bin/bash
set -e

# ============================================================
# Remote CC - 云端一键安装脚本
# 用法: ./install.sh <SSH_USER@HOST>
# 示例: ./install.sh root@1.2.3.4
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_HOST="${1:?Usage: ./install.sh <SSH_USER@HOST>}"
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

ssh_remote() {
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"
}

run_remote_bash_with_retry() {
    local label="$1"
    local attempt=1
    local max_attempts=3
    local script

    script=$(cat)

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "  ${label}: retry $attempt/$max_attempts..."
            sleep 2
        fi

        if printf '%s' "$script" | ssh_remote bash; then
            return 0
        fi

        attempt=$((attempt + 1))
    done

    echo "  ERROR: ${label} failed after $max_attempts attempts"
    return 1
}

upload_cloud_setup() {
    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "  Upload retry $attempt/$max_attempts..."
            sleep 2
        else
            echo "  Uploading setup bundle..."
        fi

        if COPYFILE_DISABLE=1 tar -C "$SCRIPT_DIR" -czf - hooks claude-config prepare-session.sh memory-sync.sh | \
            ssh_remote "rm -rf /tmp/remote-cc-setup && mkdir -p /tmp/remote-cc-setup && tar -xzf - -C /tmp/remote-cc-setup"; then
            echo "  Files uploaded"
            return 0
        fi

        attempt=$((attempt + 1))
    done

    echo "  ERROR: Failed to upload setup files after $max_attempts attempts"
    return 1
}

echo "========================================="
echo "  Remote CC - Cloud Deploy"
echo "========================================="
echo "  Target:   $REMOTE_HOST"
echo "  MCP URL:  session-managed"
echo ""

# ---- 上传文件 ----
echo "[1/4] Uploading files..."
upload_cloud_setup

# ---- 远程安装 ----
echo "[2/4] Installing on remote..."
run_remote_bash_with_retry "Remote install" << 'INSTALL_EOF'
set -e

# 系统依赖
echo "  Installing system packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl git jq 2>/dev/null
echo "  System packages: ready"

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
run_remote_bash_with_retry "Remote configuration" << CONF_EOF
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

# 移除旧的用户级 MCP 配置，连接时由会话级 .mcp.json 动态生成
su - cc -c 'export PATH="\$HOME/.local/bin:\$PATH" && claude mcp remove local-bridge 2>/dev/null || true' 2>&1

# workspace → cc 用户目录
mkdir -p "\$CC_HOME/workspace"
chown -R cc:cc "\$CC_HOME/.claude" "\$CC_HOME/workspace"

# 清理
rm -rf /tmp/remote-cc-setup
CONF_EOF

# ---- 验证 ----
echo "[4/4] Verifying..."
run_remote_bash_with_retry "Remote verification" << 'VERIFY_EOF'
CC_HOME=$(eval echo ~cc)
echo "  Claude:   $(su - cc -c '~/.local/bin/claude --version 2>/dev/null || claude --version 2>/dev/null')"
echo "  Hook:     $(test -x /opt/remote-cc/hooks/block-builtin.sh && echo 'OK' || echo 'MISSING')"
echo "  Settings: $(test -f "$CC_HOME/.claude/settings.json" && echo 'OK' || echo 'MISSING')"
echo "  MCP:      session-managed (.mcp.json)"
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
