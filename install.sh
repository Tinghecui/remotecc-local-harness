#!/bin/bash
# ============================================================
# Remote Claude Code — One-Line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | bash
#
# Or with a specific version:
#   curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | bash -s -- --version v1.0.0
#
# Or install + configure + deploy in one command:
#   curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | \
#     bash -s -- --host root@your-vps-ip
#
# What it does:
#   1. Checks prerequisites (git, node, ssh)
#   2. Clones/updates the repo to ~/.remote-cc
#   3. Installs local bridge dependencies
#   4. Creates 'ccc' symlink in ~/.local/bin
#   5. Optionally writes config + deploys to VPS
#   6. Prints next steps
# ============================================================

set -e

# ── Configuration ─────────────────────────────────────────
REPO_URL="${REMOTE_CC_REPO_URL:-https://github.com/Tinghecui/remotecc-local-harness.git}"
INSTALL_DIR="${REMOTE_CC_HOME:-$HOME/.remote-cc}"
BIN_DIR="$HOME/.local/bin"
VERSION=""
CLI_HOST=""
CLI_SSH_PORT=""
CLI_BRIDGE_PORT=""
CLI_ROOTS=""
FORCE_DEPLOY=0
SKIP_DEPLOY=0

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

# ── Parse arguments ───────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v) VERSION="$2"; shift 2 ;;
        --dir|-d) INSTALL_DIR="$2"; shift 2 ;;
        --host|-H) CLI_HOST="$2"; shift 2 ;;
        --ssh-port) CLI_SSH_PORT="$2"; shift 2 ;;
        --bridge-port|--port) CLI_BRIDGE_PORT="$2"; shift 2 ;;
        --roots) CLI_ROOTS="$2"; shift 2 ;;
        --deploy) FORCE_DEPLOY=1; shift ;;
        --skip-deploy) SKIP_DEPLOY=1; shift ;;
        --help|-h)
            echo "Usage: install.sh [--version <tag>] [--dir <path>] [--host <user@host>]"
            echo "                 [--ssh-port <port>] [--bridge-port <port>] [--roots <paths>]"
            echo "                 [--deploy] [--skip-deploy]"
            exit 0
            ;;
        *) shift ;;
    esac
done

TOTAL_STEPS=4
if [ -n "$CLI_HOST$CLI_SSH_PORT$CLI_BRIDGE_PORT$CLI_ROOTS" ] || [ "$FORCE_DEPLOY" = "1" ]; then
    TOTAL_STEPS=5
fi

# ── Colors ────────────────────────────────────────────────
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

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Remote Claude Code — Installer                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Check prerequisites ──────────────────────────
echo -e "${BOLD}[1/${TOTAL_STEPS}] Checking prerequisites...${NC}"

MISSING=""

if command -v git &>/dev/null; then
    ok "git $(git --version | awk '{print $3}')"
else
    fail "git not found"
    MISSING="$MISSING git"
fi

if command -v node &>/dev/null; then
    NODE_VER=$(node -v)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/^v//' | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 18 ]; then
        ok "node $NODE_VER"
    else
        fail "node $NODE_VER (need >= 18)"
        MISSING="$MISSING node>=18"
    fi
else
    fail "node not found (need >= 18)"
    MISSING="$MISSING node"
fi

if command -v ssh &>/dev/null; then
    ok "ssh"
else
    fail "ssh not found"
    MISSING="$MISSING ssh"
fi

if command -v npm &>/dev/null; then
    ok "npm $(npm -v 2>/dev/null)"
else
    fail "npm not found"
    MISSING="$MISSING npm"
fi

if [ -n "$MISSING" ]; then
    echo ""
    fail "Missing prerequisites:$MISSING"
    echo "    Install them and try again."
    exit 1
fi
echo ""

# ── Step 2: Clone or update repo ─────────────────────────
echo -e "${BOLD}[2/${TOTAL_STEPS}] Installing to $INSTALL_DIR...${NC}"

if [ -d "$INSTALL_DIR/.git" ]; then
    info "Existing installation found, updating..."
    cd "$INSTALL_DIR"

    # Stash any local changes (like .remote-cc.env edits that leaked in)
    git stash -q 2>/dev/null || true

    git fetch origin --tags -q
    if [ -n "$VERSION" ]; then
        git checkout "$VERSION" -q
        ok "Checked out $VERSION"
    else
        git checkout main -q 2>/dev/null || git checkout master -q 2>/dev/null
        git pull origin --ff-only -q 2>/dev/null || git reset --hard origin/main -q 2>/dev/null || git reset --hard origin/master -q
        ok "Updated to latest"
    fi

    # Restore stashed changes
    git stash pop -q 2>/dev/null || true
else
    if [ -n "$VERSION" ]; then
        git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$INSTALL_DIR" -q
        ok "Cloned $VERSION"
    else
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" -q
        ok "Cloned latest"
    fi
    cd "$INSTALL_DIR"
fi

CURRENT_VERSION=$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)
info "Version: $CURRENT_VERSION"
echo ""

# ── Step 3: Install dependencies ─────────────────────────
echo -e "${BOLD}[3/${TOTAL_STEPS}] Installing dependencies...${NC}"

cd "$INSTALL_DIR/local-bridge"
if npm install --silent 2>&1; then
    ok "Bridge dependencies installed"
else
    fail "npm install failed"
    exit 1
fi

# Make scripts executable
chmod +x "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/setup.sh"
ok "Scripts ready"
echo ""

# ── Step 4: Install CLI command ──────────────────────────
echo -e "${BOLD}[4/${TOTAL_STEPS}] Installing ccc command...${NC}"

mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/scripts/ccc.sh" "$BIN_DIR/ccc"
ok "Symlink: $BIN_DIR/ccc"

# Check PATH
if echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    ok "$BIN_DIR is in PATH"
else
    warn "$BIN_DIR is not in your PATH"

    # Detect shell and config file
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        bash) RC_FILE="$HOME/.bashrc" ;;
        *)    RC_FILE="$HOME/.profile" ;;
    esac

    # Add to PATH
    if ! grep -q "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
        echo '' >> "$RC_FILE"
        echo '# Remote Claude Code CLI' >> "$RC_FILE"
        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$RC_FILE"
        ok "Added $BIN_DIR to PATH in $RC_FILE"
        warn "Run 'source $RC_FILE' or open a new terminal"
    fi
fi
echo ""

# ── Optional Step 5: Configure + deploy ───────────────────
ENV_FILE="$INSTALL_DIR/.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

CONFIG_HOST="${CLI_HOST:-${REMOTE_CC_HOST:-}}"
CONFIG_SSH_PORT="${CLI_SSH_PORT:-${REMOTE_CC_SSH_PORT:-22}}"
CONFIG_BRIDGE_PORT="${CLI_BRIDGE_PORT:-${REMOTE_CC_PORT:-3100}}"
CONFIG_ROOTS="${CLI_ROOTS:-${REMOTE_CC_ROOTS:-$(build_default_roots)}}"

HAS_CONFIG_INPUT=0
if [ -n "$CLI_HOST$CLI_SSH_PORT$CLI_BRIDGE_PORT$CLI_ROOTS" ]; then
    HAS_CONFIG_INPUT=1
fi

if [ "$HAS_CONFIG_INPUT" = "1" ]; then
    if [ -z "$CONFIG_HOST" ]; then
        echo ""
        fail "Missing host. Use --host <user@host> the first time you configure install.sh."
        exit 1
    fi

    cat > "$ENV_FILE" << EOF
# Remote CC Configuration
# Generated by: install.sh ($(date +%Y-%m-%d))

# VPS SSH 地址
REMOTE_CC_HOST=$CONFIG_HOST

# SSH 端口
REMOTE_CC_SSH_PORT=$CONFIG_SSH_PORT

# MCP Bridge 端口
REMOTE_CC_PORT=$CONFIG_BRIDGE_PORT

# 本地允许访问的目录
REMOTE_CC_ROOTS=$CONFIG_ROOTS

# 远端 workspace 模式（project = 复用同一项目 workspace，session = 每次独立）
# REMOTE_CC_WORKSPACE_MODE=project

# MCP Bridge 监听地址（建议保持 127.0.0.1）
# MCP_HOST=127.0.0.1

# 云端自动分配会话端口的范围
# REMOTE_CC_REMOTE_PORT_START=43000
# REMOTE_CC_REMOTE_PORT_END=48999
EOF
fi

SHOULD_DEPLOY=0
if [ "$FORCE_DEPLOY" = "1" ]; then
    SHOULD_DEPLOY=1
fi
if [ "$HAS_CONFIG_INPUT" = "1" ] && [ "$SKIP_DEPLOY" != "1" ]; then
    SHOULD_DEPLOY=1
fi

if [ "$TOTAL_STEPS" -eq 5 ]; then
    echo -e "${BOLD}[5/${TOTAL_STEPS}] Configuring setup...${NC}"

    if [ "$HAS_CONFIG_INPUT" = "1" ]; then
        ok "Saved config: $ENV_FILE"
        info "Host: $CONFIG_HOST"
        info "SSH port: $CONFIG_SSH_PORT"
        info "Bridge port: $CONFIG_BRIDGE_PORT"
    elif [ "$FORCE_DEPLOY" = "1" ]; then
        info "Using existing config: $ENV_FILE"
    fi

    if [ "$SHOULD_DEPLOY" = "1" ]; then
        if [ -z "$CONFIG_HOST" ]; then
            echo ""
            fail "Missing host. Use --host <user@host> or set REMOTE_CC_HOST first."
            exit 1
        fi

        if [ ! -f "$ENV_FILE" ]; then
            echo ""
            fail "No config found at $ENV_FILE"
            echo "    Pass --host to create one, or run 'ccc setup' after install."
            exit 1
        fi

        export REMOTE_CC_SSH_PORT="$CONFIG_SSH_PORT"
        export REMOTE_CC_PORT="$CONFIG_BRIDGE_PORT"
        export REMOTE_CC_ROOTS="$CONFIG_ROOTS"
        echo ""
        "$INSTALL_DIR/setup.sh" "$CONFIG_HOST"
    elif [ "$SKIP_DEPLOY" = "1" ]; then
        info "Deployment skipped (--skip-deploy)"
    fi

    echo ""
fi

# ── Done ─────────────────────────────────────────────────
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ✅ Installation Complete!                        ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
if [ "$SHOULD_DEPLOY" = "1" ]; then
echo -e "${BOLD}║  Remote CC is ready.                             ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  Start coding:                                   ║${NC}"
echo -e "${BOLD}║     ccc                                          ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
else
echo -e "${BOLD}║  Next steps:                                     ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  1. Configure your VPS:                          ║${NC}"
echo -e "${BOLD}║     ccc setup                                    ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  2. Start coding:                                ║${NC}"
echo -e "${BOLD}║     ccc                                          ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
fi
echo -e "${BOLD}║  Installed to: $INSTALL_DIR$(printf '%*s' $((33 - ${#INSTALL_DIR})) '')║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
