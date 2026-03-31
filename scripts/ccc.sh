#!/bin/bash
# ============================================================
# ccc — Remote Claude Code CLI
#
# Usage:
#   ccc                     Start remote session (auto bridge + connect)
#   ccc setup               Interactive first-time setup wizard
#   ccc status              Check bridge & VPS status
#   ccc update              Update to latest version + redeploy VPS
#   ccc help                Show this help
#   ccc -d                  Start with --dangerously-skip-permissions
#   ccc root@1.2.3.4        Connect to a different server
# ============================================================

set -e

# Resolve the real script location so the CLI works when launched via symlink.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    TARGET="$(readlink "$SOURCE")"
    if [[ "$TARGET" != /* ]]; then
        SOURCE="$SCRIPT_DIR/$TARGET"
    else
        SOURCE="$TARGET"
    fi
done

SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.remote-cc.env"

# 加载配置
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# ── 参数解析 ──────────────────────────────────────────────
SUBCOMMAND=""
SSH_HOST_OVERRIDE=""
CLAUDE_ARGS=()

for arg in "$@"; do
    case "$arg" in
        setup|status|help|update)
            SUBCOMMAND="$arg"
            ;;
        -d)
            CLAUDE_ARGS+=("--dangerously-skip-permissions")
            ;;
        --*)
            CLAUDE_ARGS+=("$arg")
            ;;
        *@*)
            SSH_HOST_OVERRIDE="$arg"
            ;;
        *)
            # 裸 IP / 域名 → 默认 root@
            if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$arg" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
                SSH_HOST_OVERRIDE="root@$arg"
            else
                echo "Unknown argument: $arg"
                echo "Run 'ccc help' for usage."
                exit 1
            fi
            ;;
    esac
done

# ── 子命令路由 ────────────────────────────────────────────

case "$SUBCOMMAND" in
    help)
        echo "ccc — Remote Claude Code CLI"
        echo ""
        echo "Usage:"
        echo "  ccc                     Start remote session (auto bridge + connect)"
        echo "  ccc setup               Interactive first-time setup wizard"
        echo "  ccc update              Update to latest version + redeploy VPS"
        echo "  ccc status              Check bridge & VPS status"
        echo "  ccc help                Show this help"
        echo ""
        echo "Options:"
        echo "  -d                      Enable --dangerously-skip-permissions"
        echo "  --<flag>                Pass any flag through to remote claude"
        echo "  root@<ip>               Connect to a specific server (overrides config)"
        echo "  <ip>                    Same as root@<ip>"
        exit 0
        ;;

    setup)
        exec "$SCRIPT_DIR/setup-wizard.sh"
        ;;

    status)
        exec "$SCRIPT_DIR/status.sh" ${SSH_HOST_OVERRIDE:-}
        ;;

    update)
        echo "ccc — Updating Remote Claude Code..."
        echo ""

        cd "$PROJECT_DIR"

        # Check for uncommitted changes
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            echo "  Warning: You have local changes. Stashing..."
            git stash -q
            STASHED=1
        fi

        # Pull latest
        BEFORE=$(git rev-parse --short HEAD)
        git fetch origin -q
        git pull origin --ff-only -q 2>/dev/null || {
            echo "  ERROR: Cannot fast-forward. You have diverged from remote."
            echo "  Run 'cd $PROJECT_DIR && git pull' manually."
            [ "${STASHED:-}" = "1" ] && git stash pop -q 2>/dev/null
            exit 1
        }
        AFTER=$(git rev-parse --short HEAD)

        if [ "$BEFORE" = "$AFTER" ]; then
            echo "  Already up to date ($AFTER)"
        else
            echo "  Updated: $BEFORE → $AFTER"
            echo ""
            echo "  Changes:"
            git log --oneline "$BEFORE".."$AFTER" | sed 's/^/    /'
        fi

        # Restore stashed changes
        [ "${STASHED:-}" = "1" ] && git stash pop -q 2>/dev/null && echo "  Local changes restored."

        # Reinstall dependencies
        echo ""
        echo "  Updating bridge dependencies..."
        cd "$PROJECT_DIR/local-bridge"
        npm install --silent 2>&1
        echo "  Done."

        # Redeploy to VPS if configured
        CLOUD_HOST="${REMOTE_CC_HOST:-}"
        if [ -n "$CLOUD_HOST" ]; then
            echo ""
            read -p "  Redeploy to $CLOUD_HOST? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                export REMOTE_CC_SSH_PORT="${REMOTE_CC_SSH_PORT:-22}"
                "$PROJECT_DIR/setup.sh" "$CLOUD_HOST"
            fi
        fi

        echo ""
        echo "  Update complete! Run 'ccc' to start."
        exit 0
        ;;
esac

# ── 默认：启动连接 ────────────────────────────────────────

CLOUD_HOST="${SSH_HOST_OVERRIDE:-${REMOTE_CC_HOST:-}}"

if [ -z "$CLOUD_HOST" ]; then
    echo "No server configured."
    echo ""
    echo "Run 'ccc setup' to configure, or specify a host:"
    echo "  ccc root@your-vps-ip"
    exit 1
fi

BRIDGE_PORT="${REMOTE_CC_PORT:-3100}"

# ── 自动启动 Bridge ──────────────────────────────────────
if ! curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    echo "Starting MCP Bridge (port $BRIDGE_PORT)..."

    # 后台启动 bridge，日志写到临时文件
    BRIDGE_LOG="/tmp/remote-cc-bridge-$$.log"
    "$SCRIPT_DIR/start-bridge.sh" > "$BRIDGE_LOG" 2>&1 &
    BRIDGE_PID=$!

    # 等待 bridge 就绪
    WAIT_MAX=15
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $WAIT_MAX ]; do
        if curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
            echo "  Bridge started (PID $BRIDGE_PID)"
            break
        fi
        # 检查进程是否还活着
        if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
            echo "  ERROR: Bridge failed to start. Log:"
            tail -20 "$BRIDGE_LOG"
            exit 1
        fi
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ $WAIT_COUNT -ge $WAIT_MAX ]; then
        echo "  ERROR: Bridge did not become ready in ${WAIT_MAX}s"
        echo "  Check log: $BRIDGE_LOG"
        kill "$BRIDGE_PID" 2>/dev/null
        exit 1
    fi
else
    echo "Bridge already running on port $BRIDGE_PORT"
fi

# ── 连接 VPS ─────────────────────────────────────────────
CONNECT_ARGS=("$CLOUD_HOST")

# 透传 Claude 参数
if [ ${#CLAUDE_ARGS[@]} -gt 0 ]; then
    CONNECT_ARGS+=("${CLAUDE_ARGS[@]}")
fi

exec "$SCRIPT_DIR/connect.sh" "${CONNECT_ARGS[@]}"
