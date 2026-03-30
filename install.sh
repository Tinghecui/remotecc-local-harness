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
# What it does:
#   1. Checks prerequisites (git, node, ssh)
#   2. Clones/updates the repo to ~/.remote-cc
#   3. Installs local bridge dependencies
#   4. Creates 'ccc' symlink in ~/.local/bin
#   5. Prints next steps
# ============================================================

set -e

# ── Configuration ─────────────────────────────────────────
REPO_URL="https://github.com/Tinghecui/remotecc-local-harness.git"
INSTALL_DIR="${REMOTE_CC_HOME:-$HOME/.remote-cc}"
BIN_DIR="$HOME/.local/bin"
VERSION=""

# ── Parse arguments ───────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v) VERSION="$2"; shift 2 ;;
        --dir|-d) INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [--version <tag>] [--dir <path>]"
            exit 0
            ;;
        *) shift ;;
    esac
done

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
echo -e "${BOLD}[1/4] Checking prerequisites...${NC}"

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
echo -e "${BOLD}[2/4] Installing to $INSTALL_DIR...${NC}"

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
echo -e "${BOLD}[3/4] Installing dependencies...${NC}"

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
echo -e "${BOLD}[4/4] Installing ccc command...${NC}"

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

# ── Done ─────────────────────────────────────────────────
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ✅ Installation Complete!                        ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  Next steps:                                     ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  1. Configure your VPS:                          ║${NC}"
echo -e "${BOLD}║     ccc setup                                    ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  2. Start coding:                                ║${NC}"
echo -e "${BOLD}║     ccc                                          ║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}║  Installed to: $INSTALL_DIR$(printf '%*s' $((33 - ${#INSTALL_DIR})) '')║${NC}"
echo -e "${BOLD}║                                                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
