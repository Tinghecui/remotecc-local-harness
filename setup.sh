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
# 示例: ./setup.sh root@1.2.3.4
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
SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
SSH_KEY="${REMOTE_CC_SSH_KEY:-}"
VERIFY_ROOTS="${REMOTE_CC_ROOTS:-$(build_default_roots)}"
SSH_BASE_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SSH_PORT_FLAG=()
SSH_KEY_FLAG=()
if [ "$SSH_PORT" != "22" ]; then
    SSH_PORT_FLAG=(-p "$SSH_PORT")
fi
if [ -n "$SSH_KEY" ]; then
    SSH_KEY_FLAG=(-i "$SSH_KEY")
fi

ssh_remote() {
    ssh "${SSH_BASE_OPTS[@]}" "${SSH_PORT_FLAG[@]}" "${SSH_KEY_FLAG[@]}" "$REMOTE_HOST" "$@"
}

check_ssh_with_retry() {
    local err_file="$1"
    local attempt=1
    local max_attempts=3

    : > "$err_file"

    while [ "$attempt" -le "$max_attempts" ]; do
        if ssh_remote "echo ok" > /dev/null 2>"$err_file"; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    return 1
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

        if COPYFILE_DISABLE=1 tar -C "$SCRIPT_DIR/cloud-setup" -czf - \
            hooks \
            claude-config \
            prepare-session.sh \
            memory-sync.sh | \
            ssh_remote "rm -rf /tmp/remote-cc-setup && mkdir -p /tmp/remote-cc-setup && tar -xzf - -C /tmp/remote-cc-setup"; then
            echo "  Files uploaded"
            return 0
        fi

        attempt=$((attempt + 1))
    done

    echo "  ERROR: Failed to upload setup files after $max_attempts attempts"
    return 1
}

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
SSH_CHECK_ERR=$(mktemp)
if ! check_ssh_with_retry "$SSH_CHECK_ERR"; then
    echo "  ERROR: Cannot SSH to $REMOTE_HOST"
    if [ -s "$SSH_CHECK_ERR" ]; then
        sed 's/^/  SSH says: /' "$SSH_CHECK_ERR"
    fi
    if [ -n "$SSH_KEY" ]; then
        echo "  Checked with key: $SSH_KEY"
    fi
    SSH_EXAMPLE_CMD="ssh "
    if [ -n "$SSH_KEY" ]; then
        SSH_EXAMPLE_CMD="${SSH_EXAMPLE_CMD}-i $SSH_KEY "
    fi
    if [ "$SSH_PORT" != "22" ]; then
        SSH_EXAMPLE_CMD="${SSH_EXAMPLE_CMD}-p $SSH_PORT "
    fi
    SSH_EXAMPLE_CMD="${SSH_EXAMPLE_CMD}$REMOTE_HOST"
    echo "  Make sure the configured SSH options are correct."
    echo "  Example: $SSH_EXAMPLE_CMD"
    rm -f "$SSH_CHECK_ERR"
    exit 1
fi
rm -f "$SSH_CHECK_ERR"
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
upload_cloud_setup

# 安装 Claude Code
run_remote_bash_with_retry "Remote install" << 'REMOTE_INSTALL'
set -e
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
    echo "  Installing Claude Code for cc user (first run can take ~30s)..."
    su - cc -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1
    su - cc -c 'echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'
else
    echo "  Claude Code: already installed"
fi
echo "  Claude Code: $(su - cc -c '~/.local/bin/claude --version 2>/dev/null || claude --version 2>/dev/null')"

# 以 cc 用户安装插件
echo "  Configuring Claude plugins..."
su - cc -c 'export PATH="$HOME/.local/bin:$PATH" && claude plugins marketplace add https://github.com/anthropics/skills.git 2>/dev/null || true'
su - cc -c 'export PATH="$HOME/.local/bin:$PATH" && claude plugins install document-skills@anthropic-agent-skills 2>/dev/null' && \
    echo "  Plugin: document-skills installed" || \
    echo "  Plugin: document-skills install skipped (may need manual install)"
REMOTE_INSTALL

# 配置 Hook + MCP
run_remote_bash_with_retry "Remote configuration" << REMOTE_CONFIG
set -e

# Hook + prepare-session（全局目录，root 部署）
mkdir -p /opt/remote-cc/hooks
cp /tmp/remote-cc-setup/hooks/block-builtin.sh /opt/remote-cc/hooks/
chmod +x /opt/remote-cc/hooks/block-builtin.sh
cp /tmp/remote-cc-setup/prepare-session.sh /opt/remote-cc/
chmod +x /opt/remote-cc/prepare-session.sh
cp /tmp/remote-cc-setup/memory-sync.sh /opt/remote-cc/
chmod +x /opt/remote-cc/memory-sync.sh

# Settings → cc 用户目录
CC_HOME=\$(eval echo ~cc)
mkdir -p "\$CC_HOME/.claude"
cp /tmp/remote-cc-setup/claude-config/settings.json "\$CC_HOME/.claude/settings.json"

# MCP (SSE, no auth - secured by SSH tunnel) → cc 用户
su - cc -c 'export PATH="\$HOME/.local/bin:\$PATH" && claude mcp remove local-bridge 2>/dev/null || true && claude mcp add -t sse -s user -- local-bridge http://127.0.0.1:${BRIDGE_PORT}/sse' 2>&1

# workspace → cc 用户目录
mkdir -p "\$CC_HOME/workspace"
chown -R cc:cc "\$CC_HOME/.claude" "\$CC_HOME/workspace"

# Cleanup
rm -rf /tmp/remote-cc-setup
REMOTE_CONFIG
echo "  Cloud configured"

# ===== Step 4: 快速验证 =====
echo ""
echo "[4/5] Verifying..."

# 启动本地 Bridge（后台临时验证）
BRIDGE_STARTED_FOR_VERIFY=0
if curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    echo "  Local bridge already running on port $BRIDGE_PORT"
else
    MCP_ALLOWED_ROOTS="$VERIFY_ROOTS" \
    MCP_HOST="127.0.0.1" \
    MCP_PORT="$BRIDGE_PORT" \
    npx tsx "$SCRIPT_DIR/local-bridge/src/index.ts" &
    BRIDGE_PID=$!
    BRIDGE_STARTED_FOR_VERIFY=1
    sleep 3
fi

# 通过 SSH 隧道验证连通性
HEALTH=$(ssh "${SSH_BASE_OPTS[@]}" "${SSH_PORT_FLAG[@]}" "${SSH_KEY_FLAG[@]}" -R "$BRIDGE_PORT:localhost:$BRIDGE_PORT" "$REMOTE_HOST" \
  "curl -s http://127.0.0.1:$BRIDGE_PORT/health 2>/dev/null" || echo "FAILED")

if [ "$BRIDGE_STARTED_FOR_VERIFY" = "1" ]; then
    kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null || true
fi

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
echo "║  If you ran 'ccc setup', just type:              ║"
echo "║                                                  ║"
echo "║    ccc              Start remote session          ║"
echo "║    ccc -d           Skip permissions mode         ║"
echo "║    ccc status       Check status                  ║"
echo "║                                                  ║"
echo "║  Or use scripts directly:                        ║"
echo "║    ./scripts/start-bridge.sh                     ║"
echo "║    ./scripts/connect.sh ${REMOTE_HOST}$(printf '%*s' $((21 - ${#REMOTE_HOST})) '')║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
