#!/bin/bash
# ============================================================
# ccc — Remote Claude Code CLI
#
# Usage:
#   ccc                     Start remote session (auto bridge + tunnel + connect)
#   ccc setup               Interactive first-time setup wizard
#   ccc status              Check bridge, tunnel & VPS status
#   ccc tunnel              Start persistent SSH tunnel manually
#   ccc tunnel-stop         Stop persistent SSH tunnel
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
EXPECT_SESSION_ID=""

for arg in "$@"; do
    # If previous arg was "resume", check if this is a session ID
    if [ -n "$EXPECT_SESSION_ID" ]; then
        case "$arg" in
            setup|status|help|update|resume|continue|c|-d|--*)
                # Not a session ID; emit bare --resume and re-process
                CLAUDE_ARGS+=("--resume")
                EXPECT_SESSION_ID=""
                ;;
            *)
                # Treat as session ID
                CLAUDE_ARGS+=("--resume=$arg")
                EXPECT_SESSION_ID=""
                continue
                ;;
        esac
    fi

    case "$arg" in
        setup|status|help|update|tunnel|tunnel-stop)
            SUBCOMMAND="$arg"
            ;;
        resume)
            EXPECT_SESSION_ID=1
            ;;
        continue|c)
            CLAUDE_ARGS+=("--continue")
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

# Handle trailing "resume" with no session ID
if [ -n "$EXPECT_SESSION_ID" ]; then
    CLAUDE_ARGS+=("--resume")
fi

# ── 子命令路由 ────────────────────────────────────────────

case "$SUBCOMMAND" in
    help)
        echo "ccc — Remote Claude Code CLI"
        echo ""
        echo "Usage:"
        echo "  ccc                     Start remote session (auto bridge + tunnel + connect)"
        echo "  ccc continue (or c)     Resume last session in this project"
        echo "  ccc resume              Open session picker on VPS"
        echo "  ccc resume <session-id> Resume a specific session"
        echo "  ccc tunnel              Start persistent SSH tunnel manually"
        echo "  ccc tunnel-stop         Stop persistent SSH tunnel"
        echo "  ccc setup               Interactive first-time setup wizard"
        echo "  ccc update              Update to latest version + redeploy VPS"
        echo "  ccc status              Check bridge, tunnel & VPS status"
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

        # 从远程下载最新 install.sh 并执行（全量替换 + 可选 redeploy）
        INSTALLER_URL="${REMOTE_CC_REPO_URL:-https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh}"

        INSTALL_ARGS=()
        CLOUD_HOST="${REMOTE_CC_HOST:-}"
        if [ -n "$CLOUD_HOST" ]; then
            echo "  VPS configured: $CLOUD_HOST"
            read -p "  Redeploy to VPS after update? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                INSTALL_ARGS+=(--deploy)
            else
                INSTALL_ARGS+=(--skip-deploy)
            fi
        fi

        echo "  Downloading latest installer..."
        exec bash <(curl -fsSL "$INSTALLER_URL") "${INSTALL_ARGS[@]}"
        ;;

    tunnel)
        exec "$SCRIPT_DIR/start-tunnel.sh" ${SSH_HOST_OVERRIDE:-}
        ;;

    tunnel-stop)
        TUNNEL_STATE_FILE="${REMOTE_CC_TUNNEL_STATE_FILE:-/tmp/remote-cc-tunnel.json}"
        if [ ! -f "$TUNNEL_STATE_FILE" ]; then
            echo "No tunnel running (state file not found)."
            exit 0
        fi
        TUNNEL_PID=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
        if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
            echo "Stopping tunnel (PID $TUNNEL_PID)..."
            kill "$TUNNEL_PID"
            sleep 1
            kill -0 "$TUNNEL_PID" 2>/dev/null && kill -9 "$TUNNEL_PID" 2>/dev/null
            echo "Tunnel stopped."
        else
            echo "Tunnel process not running (stale state file)."
        fi
        rm -f "$TUNNEL_STATE_FILE"
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
    nohup "$SCRIPT_DIR/start-bridge.sh" > "$BRIDGE_LOG" 2>&1 </dev/null &
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

# ── 自动启动持久化隧道 ──────────────────────────────────
TUNNEL_STATE_FILE="${REMOTE_CC_TUNNEL_STATE_FILE:-/tmp/remote-cc-tunnel.json}"
TUNNEL_RUNNING=false

if [ -f "$TUNNEL_STATE_FILE" ] && command -v jq &>/dev/null; then
    TUNNEL_PID=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        TUNNEL_RUNNING=true
        echo "Tunnel already running (PID $TUNNEL_PID)"
    fi
fi

if [ "$TUNNEL_RUNNING" = false ]; then
    echo "Starting SSH tunnel..."

    TUNNEL_LOG="/tmp/remote-cc-tunnel-$$.log"
    nohup "$SCRIPT_DIR/start-tunnel.sh" ${SSH_HOST_OVERRIDE:-} > "$TUNNEL_LOG" 2>&1 </dev/null &
    TUNNEL_STARTER_PID=$!

    # 等待隧道就绪（状态文件出现且 PID 存活）
    WAIT_MAX=15
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $WAIT_MAX ]; do
        if [ -f "$TUNNEL_STATE_FILE" ]; then
            TUNNEL_PID=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
            if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
                echo "  Tunnel started (PID $TUNNEL_PID)"
                TUNNEL_RUNNING=true
                break
            fi
        fi
        # 检查启动进程是否还活着
        if ! kill -0 "$TUNNEL_STARTER_PID" 2>/dev/null; then
            # 启动进程退出了，再检查一次状态文件
            if [ -f "$TUNNEL_STATE_FILE" ]; then
                TUNNEL_PID=$(jq -r '.pid // empty' "$TUNNEL_STATE_FILE" 2>/dev/null)
                if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
                    echo "  Tunnel started (PID $TUNNEL_PID)"
                    TUNNEL_RUNNING=true
                    break
                fi
            fi
            echo "  ERROR: Tunnel failed to start. Log:"
            tail -20 "$TUNNEL_LOG"
            exit 1
        fi
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ "$TUNNEL_RUNNING" = false ]; then
        echo "  ERROR: Tunnel did not start in ${WAIT_MAX}s"
        echo "  Check log: $TUNNEL_LOG"
        kill "$TUNNEL_STARTER_PID" 2>/dev/null
        exit 1
    fi
fi

# ── 连接 VPS ─────────────────────────────────────────────
CONNECT_ARGS=("$CLOUD_HOST")

# 透传 Claude 参数
if [ ${#CLAUDE_ARGS[@]} -gt 0 ]; then
    CONNECT_ARGS+=("${CLAUDE_ARGS[@]}")
fi

exec "$SCRIPT_DIR/connect.sh" "${CONNECT_ARGS[@]}"
