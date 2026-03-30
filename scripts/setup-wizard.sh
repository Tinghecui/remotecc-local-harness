#!/bin/bash
# ============================================================
# ccc setup — Interactive Setup Wizard
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.remote-cc.env"

# 加载已有配置（用于显示默认值）
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# ── 工具函数 ──────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
info() { printf "  ${CYAN}→${NC} %s\n" "$1"; }

# 读取用户输入，支持默认值
# ask "prompt" "default" → 结果存入 REPLY
ask() {
    local prompt="$1"
    local default="$2"
    if [ -n "$default" ]; then
        printf "    %s [${BOLD}%s${NC}]: " "$prompt" "$default"
    else
        printf "    %s: " "$prompt"
    fi
    read -r REPLY
    REPLY="${REPLY:-$default}"
}

# 读取 yes/no
# ask_yn "prompt" "default(y/n)" → 返回 0 (yes) 或 1 (no)
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint="Y/n"
    [ "$default" = "n" ] && hint="y/N"
    printf "    %s [%s]: " "$prompt" "$hint"
    read -r REPLY
    REPLY="${REPLY:-$default}"
    [[ "$REPLY" =~ ^[Yy] ]]
}

# 从已有配置解析 user 和 host
parse_existing_host() {
    local host_str="${REMOTE_CC_HOST:-}"
    if [[ "$host_str" == *@* ]]; then
        EXISTING_USER="${host_str%%@*}"
        EXISTING_IP="${host_str#*@}"
    else
        EXISTING_USER=""
        EXISTING_IP="$host_str"
    fi
}

parse_existing_host

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  🔧 Remote Claude Code — Setup Wizard           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if [ -f "$ENV_FILE" ]; then
    info "Found existing config: $ENV_FILE"
    info "Current values shown as defaults — press Enter to keep."
    echo ""
fi

# ══════════════════════════════════════════════════════════
# [1/6] VPS Connection
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[1/6] VPS Connection${NC}"
echo ""

ask "VPS IP address or hostname" "$EXISTING_IP"
VPS_IP="$REPLY"

if [ -z "$VPS_IP" ]; then
    fail "VPS IP is required."
    exit 1
fi

ask "SSH user" "${EXISTING_USER:-root}"
SSH_USER="$REPLY"

ask "SSH port" "${REMOTE_CC_SSH_PORT:-22}"
SSH_PORT="$REPLY"

SSH_TARGET="$SSH_USER@$VPS_IP"
echo ""

# ══════════════════════════════════════════════════════════
# [2/6] SSH Authentication
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[2/6] SSH Authentication${NC}"
echo ""

# 发现 SSH 密钥
SSH_KEYS=()
while IFS= read -r pubkey; do
    privkey="${pubkey%.pub}"
    [ -f "$privkey" ] && SSH_KEYS+=("$privkey")
done < <(ls ~/.ssh/*.pub 2>/dev/null)

SELECTED_KEY=""

if [ ${#SSH_KEYS[@]} -eq 0 ]; then
    warn "No SSH keys found in ~/.ssh/"
    echo ""
    if ask_yn "Generate a new SSH key (ed25519)?"; then
        echo ""
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "ccc@$(hostname -s)"
        echo ""
        ok "Key generated: ~/.ssh/id_ed25519"
        SELECTED_KEY="$HOME/.ssh/id_ed25519"
    else
        fail "Cannot continue without SSH keys."
        echo "    Generate one manually: ssh-keygen -t ed25519"
        exit 1
    fi
elif [ ${#SSH_KEYS[@]} -eq 1 ]; then
    SELECTED_KEY="${SSH_KEYS[0]}"
    info "Using SSH key: $SELECTED_KEY"
else
    info "Found SSH keys:"
    for i in "${!SSH_KEYS[@]}"; do
        local_key="${SSH_KEYS[$i]}"
        key_type=$(ssh-keygen -l -f "$local_key" 2>/dev/null | awk '{print $4}' || echo "unknown")
        # 推荐 ed25519
        rec=""
        [[ "$local_key" == *ed25519* ]] && rec=" (recommended)"
        printf "      %d) %s %s%s\n" "$((i+1))" "$(basename "$local_key")" "$key_type" "$rec"
    done
    echo ""
    ask "Select key" "1"
    KEY_IDX=$((REPLY - 1))
    if [ "$KEY_IDX" -lt 0 ] || [ "$KEY_IDX" -ge ${#SSH_KEYS[@]} ]; then
        fail "Invalid selection."
        exit 1
    fi
    SELECTED_KEY="${SSH_KEYS[$KEY_IDX]}"
fi

echo ""

# 构建 SSH 选项
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes -i "$SELECTED_KEY" -p "$SSH_PORT")

# 测试连接
printf "    Testing SSH connection to %s:%s..." "$SSH_TARGET" "$SSH_PORT"

if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "echo ok" > /dev/null 2>&1; then
    echo ""
    ok "Connected successfully"
else
    echo ""
    warn "Connection failed with key authentication."
    echo ""
    info "The SSH key needs to be uploaded to the server."
    echo ""

    if ask_yn "Upload key via ssh-copy-id (will ask for password)?"; then
        echo ""
        # ssh-copy-id 需要交互输入密码，不能用 BatchMode
        ssh-copy-id -i "$SELECTED_KEY" -p "$SSH_PORT" "$SSH_TARGET"
        echo ""

        # 重新测试
        printf "    Re-testing connection..."
        if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "echo ok" > /dev/null 2>&1; then
            echo ""
            ok "Connected successfully"
        else
            echo ""
            fail "Still cannot connect. Please check manually:"
            echo "      ssh -i $SELECTED_KEY -p $SSH_PORT $SSH_TARGET"
            exit 1
        fi
    else
        echo ""
        echo "    Manual setup options:"
        echo "      1) Upload key:     ssh-copy-id -i $SELECTED_KEY -p $SSH_PORT $SSH_TARGET"
        echo "      2) Copy manually:  cat ${SELECTED_KEY}.pub | ssh -p $SSH_PORT $SSH_TARGET 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'"
        echo "      3) If using password auth, ensure the server allows it in /etc/ssh/sshd_config"
        echo ""
        fail "Run 'ccc setup' again after fixing SSH access."
        exit 1
    fi
fi

# 获取服务器信息
echo ""
SERVER_INFO=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "uname -n; nproc 2>/dev/null || echo '?'; free -h 2>/dev/null | awk '/Mem:/{print \$2}' || echo '?'" 2>/dev/null || echo "unknown")
SERVER_HOSTNAME=$(echo "$SERVER_INFO" | head -1)
SERVER_CPUS=$(echo "$SERVER_INFO" | sed -n '2p')
SERVER_MEM=$(echo "$SERVER_INFO" | sed -n '3p')
info "Server: $SERVER_HOSTNAME (${SERVER_CPUS} CPU, ${SERVER_MEM} RAM)"
echo ""

# ══════════════════════════════════════════════════════════
# [3/6] Bridge Configuration
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[3/6] Bridge Configuration${NC}"
echo ""

ask "MCP Bridge port" "${REMOTE_CC_PORT:-3100}"
BRIDGE_PORT="$REPLY"

# 检查端口占用
if lsof -ti:"$BRIDGE_PORT" > /dev/null 2>&1; then
    warn "Port $BRIDGE_PORT is currently in use."
    if ask_yn "Use this port anyway (existing bridge may be running)?"; then
        info "Will use existing bridge on port $BRIDGE_PORT"
    else
        ask "Enter a different port" "3101"
        BRIDGE_PORT="$REPLY"
    fi
fi

# 本地目录
DEFAULT_ROOTS=""
for dir in "$HOME/Desktop" "$HOME/Documents" "$HOME/projects"; do
    [ -d "$dir" ] && DEFAULT_ROOTS="${DEFAULT_ROOTS:+$DEFAULT_ROOTS,}$dir"
done

ask "Local directories to expose (comma-separated)" "${REMOTE_CC_ROOTS:-$DEFAULT_ROOTS}"
LOCAL_ROOTS="$REPLY"

echo ""

# ══════════════════════════════════════════════════════════
# [4/6] Deploy to VPS
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[4/6] Deploy to VPS${NC}"
echo ""
info "This will install Claude Code and configure the VPS."
echo ""

if ask_yn "Proceed with deployment?"; then
    echo ""
    # 设置环境变量供 setup.sh 使用
    export REMOTE_CC_SSH_PORT="$SSH_PORT"
    "$PROJECT_DIR/setup.sh" "$SSH_TARGET"
    DEPLOY_OK=$?

    if [ "${DEPLOY_OK:-0}" -ne 0 ]; then
        fail "Deployment failed. Check the output above."
        echo "    Fix the issue and run 'ccc setup' again."
        exit 1
    fi
else
    warn "Deployment skipped. You can deploy later with: ./setup.sh $SSH_TARGET"
fi

echo ""

# ══════════════════════════════════════════════════════════
# [5/6] Save Configuration
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[5/6] Save Configuration${NC}"
echo ""

# 写入 .remote-cc.env
cat > "$ENV_FILE" << EOF
# Remote CC Configuration
# Generated by: ccc setup ($(date +%Y-%m-%d))

# VPS SSH 地址
REMOTE_CC_HOST=$SSH_TARGET

# SSH 端口
REMOTE_CC_SSH_PORT=$SSH_PORT

# MCP Bridge 端口
REMOTE_CC_PORT=$BRIDGE_PORT

# 本地允许访问的目录
REMOTE_CC_ROOTS=$LOCAL_ROOTS

# MCP Bridge 监听地址（建议保持 127.0.0.1）
# MCP_HOST=127.0.0.1

# 云端自动分配会话端口的范围
# REMOTE_CC_REMOTE_PORT_START=43000
# REMOTE_CC_REMOTE_PORT_END=48999
EOF

ok "Config saved to .remote-cc.env"

# ══════════════════════════════════════════════════════════
# [6/6] Install CLI
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}[6/6] Install CLI Command${NC}"
echo ""

CCC_SCRIPT="$SCRIPT_DIR/ccc.sh"
chmod +x "$CCC_SCRIPT"
chmod +x "$SCRIPT_DIR/setup-wizard.sh"

# 确保 ~/.local/bin 存在
mkdir -p "$HOME/.local/bin"

# 创建 symlink
SYMLINK_PATH="$HOME/.local/bin/ccc"
if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
    rm -f "$SYMLINK_PATH"
fi
ln -sf "$CCC_SCRIPT" "$SYMLINK_PATH"
ok "Symlink: ~/.local/bin/ccc → scripts/ccc.sh"

# 检查 ~/.local/bin 是否在 PATH 中
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    warn "~/.local/bin is not in your PATH."
    echo ""
    info "Add this to your ~/.zshrc:"
    echo '      export PATH="$HOME/.local/bin:$PATH"'
    echo ""

    if ask_yn "Add it now?"; then
        echo '' >> "$HOME/.zshrc"
        echo '# Remote Claude Code CLI' >> "$HOME/.zshrc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
        ok "Added to ~/.zshrc — run 'source ~/.zshrc' or open a new terminal"
    fi
else
    ok "~/.local/bin is already in PATH"
fi

echo ""

# ══════════════════════════════════════════════════════════
# 完成
# ══════════════════════════════════════════════════════════
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ✅ Setup Complete!                               ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  Quick start:                                    ║${NC}"
echo -e "${BOLD}║    ccc              Start remote session          ║${NC}"
echo -e "${BOLD}║    ccc -d           Skip permissions mode         ║${NC}"
echo -e "${BOLD}║    ccc status       Check status                  ║${NC}"
echo -e "${BOLD}║    ccc setup        Re-configure                  ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  Server: ${SSH_TARGET}$(printf '%*s' $((38 - ${#SSH_TARGET})) '')║${NC}"
echo -e "${BOLD}║  Bridge: localhost:${BRIDGE_PORT}$(printf '%*s' $((29 - ${#BRIDGE_PORT})) '')║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
