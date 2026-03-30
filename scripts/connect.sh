#!/bin/bash
# ============================================================
# SSH 连接到云端并启动 Claude Code（自动建立反向隧道）
# 用法: ./connect.sh [SSH_HOST] [BRIDGE_PORT] [LOCAL_WORKDIR]
# 示例: ./connect.sh
#       ./connect.sh root@99.173.22.106
#       ./connect.sh root@my-server 3100 ~/my-project
# 不指定 LOCAL_WORKDIR 时默认使用当前目录 (pwd)
# ============================================================

# 加载配置文件
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.remote-cc.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

CLOUD_HOST="${1:-${REMOTE_CC_HOST:-}}"
BRIDGE_PORT="${2:-${REMOTE_CC_PORT:-3100}}"
LOCAL_WORKDIR="${3:-$(pwd)}"

if [ -z "$CLOUD_HOST" ]; then
    echo "Error: SSH host not specified."
    echo "Usage: ./scripts/connect.sh <SSH_USER@HOST> [BRIDGE_PORT] [LOCAL_WORKDIR]"
    echo "   or: set REMOTE_CC_HOST in .remote-cc.env"
    exit 1
fi

echo "========================================="
echo "  Remote CC - Connect"
echo "========================================="
echo "  Cloud:   $CLOUD_HOST"
echo "  Tunnel:  localhost:$BRIDGE_PORT → remote:$BRIDGE_PORT"
echo "  Local:   $LOCAL_WORKDIR"
echo ""

# 检查本地 Bridge 是否在运行
if ! curl -s "http://127.0.0.1:$BRIDGE_PORT/health" > /dev/null 2>&1; then
    echo "WARNING: Local MCP Bridge is not running on port $BRIDGE_PORT"
    echo "  Start it first:  ./scripts/start-bridge.sh"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Connecting... (Ctrl+D or /exit to quit)"
echo ""

LOCAL_WORKDIR_B64=$(printf '%s' "$LOCAL_WORKDIR" | base64 | tr -d '\n')

# ============================================================
# 检测本地 SSE 类型 MCP 服务器，自动添加隧道
# ============================================================
SSE_MCP_TUNNELS=""
SSE_MCP_PORTS_SEEN=""

if command -v jq &>/dev/null && [ -f "$HOME/.claude.json" ]; then
    while IFS= read -r mcp_entry; do
        [ -z "$mcp_entry" ] && continue
        mcp_name=$(echo "$mcp_entry" | jq -r '.name')
        mcp_url=$(echo "$mcp_entry" | jq -r '.url')

        # 从 URL 提取端口号（如 http://localhost:4000/sse → 4000）
        mcp_port=$(echo "$mcp_url" | sed -n 's|.*://[^:]*:\([0-9]*\).*|\1|p')

        if [ -z "$mcp_port" ]; then
            echo "  WARNING: Cannot extract port from SSE MCP '$mcp_name' URL: $mcp_url, skipping"
            continue
        fi

        # 跳过与 bridge 相同的端口
        if [ "$mcp_port" = "$BRIDGE_PORT" ]; then
            continue
        fi

        # 跳过重复端口
        if echo "$SSE_MCP_PORTS_SEEN" | grep -q ":${mcp_port}:"; then
            continue
        fi
        SSE_MCP_PORTS_SEEN="${SSE_MCP_PORTS_SEEN}:${mcp_port}:"

        echo "  Found SSE MCP: $mcp_name → port $mcp_port"
        SSE_MCP_TUNNELS="$SSE_MCP_TUNNELS -R $mcp_port:localhost:$mcp_port"
    done < <(jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "sse") | {name: .key, url: .value.url} | @json' "$HOME/.claude.json" 2>/dev/null)
fi

# 上传本地 CLAUDE.md 文件（用户级 + 项目级）
ssh "$CLOUD_HOST" "rm -f /tmp/local-claude-user.md /tmp/local-claude-project.md" 2>/dev/null

# 用户级 CLAUDE.md（~/.claude/CLAUDE.md）
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "  Uploading user-level CLAUDE.md..."
    scp -q "$HOME/.claude/CLAUDE.md" "$CLOUD_HOST:/tmp/local-claude-user.md"
fi

# 项目级 CLAUDE.md（工作目录下的）
if [ -f "$LOCAL_WORKDIR/CLAUDE.md" ]; then
    echo "  Uploading project-level CLAUDE.md..."
    scp -q "$LOCAL_WORKDIR/CLAUDE.md" "$CLOUD_HOST:/tmp/local-claude-project.md"
fi

# 上传配置文件（settings、skills、commands）
echo "  Syncing config..."
ssh "$CLOUD_HOST" "rm -rf /tmp/local-settings-*.json /tmp/local-skills-* /tmp/local-commands-*" 2>/dev/null

# 用户级 settings.json
[ -f "$HOME/.claude/settings.json" ] && \
    scp -q "$HOME/.claude/settings.json" "$CLOUD_HOST:/tmp/local-settings-user.json"

# 用户级 settings.local.json（权限设置）
[ -f "$HOME/.claude/settings.local.json" ] && \
    scp -q "$HOME/.claude/settings.local.json" "$CLOUD_HOST:/tmp/local-settings-local-user.json"

# 用户级 skills/
[ -d "$HOME/.claude/skills" ] && [ "$(ls -A "$HOME/.claude/skills" 2>/dev/null)" ] && \
    scp -q -r "$HOME/.claude/skills" "$CLOUD_HOST:/tmp/local-skills-user"

# 用户级 commands/
[ -d "$HOME/.claude/commands" ] && [ "$(ls -A "$HOME/.claude/commands" 2>/dev/null)" ] && \
    scp -q -r "$HOME/.claude/commands" "$CLOUD_HOST:/tmp/local-commands-user"

# 项目级 .claude/settings.json
[ -f "$LOCAL_WORKDIR/.claude/settings.json" ] && \
    scp -q "$LOCAL_WORKDIR/.claude/settings.json" "$CLOUD_HOST:/tmp/local-settings-project.json"

# 项目级 .claude/settings.local.json（权限设置）
[ -f "$LOCAL_WORKDIR/.claude/settings.local.json" ] && \
    scp -q "$LOCAL_WORKDIR/.claude/settings.local.json" "$CLOUD_HOST:/tmp/local-settings-local-project.json"

# 项目级 .claude/skills/
[ -d "$LOCAL_WORKDIR/.claude/skills" ] && [ "$(ls -A "$LOCAL_WORKDIR/.claude/skills" 2>/dev/null)" ] && \
    scp -q -r "$LOCAL_WORKDIR/.claude/skills" "$CLOUD_HOST:/tmp/local-skills-project"

# 上传 SSE MCP 列表供云端注册
if [ -n "$SSE_MCP_TUNNELS" ]; then
    jq -r '.mcpServers // {} | to_entries[] | select(.value.type == "sse") | {name: .key, url: .value.url} | @json' "$HOME/.claude.json" 2>/dev/null \
        | ssh "$CLOUD_HOST" "cat > /tmp/local-sse-mcps.json"
    echo "  SSE MCP list: uploaded"
else
    ssh "$CLOUD_HOST" "rm -f /tmp/local-sse-mcps.json" 2>/dev/null
fi

# SSH 反向隧道 + 启动 claude
# -t: 分配伪终端（claude 需要交互式终端）
# -R: 反向隧道，让云端 localhost:PORT 指向本地 localhost:PORT
# SSE_MCP_TUNNELS: 额外的 SSE MCP 隧道端口
# LOCAL_WORKDIR: 传递本地工作目录，用于生成 CLAUDE.md 上下文
ssh -t \
    -R "$BRIDGE_PORT:localhost:$BRIDGE_PORT" \
    $SSE_MCP_TUNNELS \
    "$CLOUD_HOST" \
    "export PATH=\$HOME/.local/bin:\$PATH && export BRIDGE_PORT='$BRIDGE_PORT' && export REMOTE_CC_LOCAL_DIR=\$(printf '%s' '$LOCAL_WORKDIR_B64' | base64 -d) && /opt/remote-cc/prepare-session.sh && cd ~/workspace && claude"
