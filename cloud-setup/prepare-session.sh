#!/bin/bash
# ============================================================
# 每次 connect.sh 连接时在云端执行
# 同步本地配置到云端，动态生成 ~/workspace/CLAUDE.md
#
# 从 /tmp/local-* 读取 connect.sh 上传的文件：
#   /tmp/local-claude-user.md        → ~/.claude/CLAUDE.md
#   /tmp/local-claude-project.md     → ~/workspace/CLAUDE.md
#   /tmp/local-settings-user.json    → merge into ~/.claude/settings.json
#   /tmp/local-settings-project.json → merge into ~/workspace/.claude/settings.json
#   /tmp/local-skills-user/          → ~/.claude/skills/
#   /tmp/local-commands-user/        → ~/.claude/commands/
#   /tmp/local-skills-project/       → ~/workspace/.claude/skills/
#
# 环境变量: REMOTE_CC_LOCAL_DIR — 本地工作目录路径
# ============================================================

LOCAL_DIR="${REMOTE_CC_LOCAL_DIR:-unknown}"
WORKSPACE="$HOME/workspace"

mkdir -p "$WORKSPACE"

# ============================================================
# 1. CLAUDE.md 同步
# ============================================================

# 用户级 CLAUDE.md
if [ -f /tmp/local-claude-user.md ]; then
    mkdir -p "$HOME/.claude"
    cp /tmp/local-claude-user.md "$HOME/.claude/CLAUDE.md"
    rm -f /tmp/local-claude-user.md
    echo "  User CLAUDE.md: synced"
fi

# ============================================================
# 2. settings.json 合并（保留云端 hooks）
# ============================================================

merge_settings() {
    local LOCAL_FILE="$1"
    local CLOUD_FILE="$2"
    local LABEL="$3"

    if [ ! -f "$LOCAL_FILE" ]; then
        return
    fi

    if ! command -v jq &>/dev/null; then
        echo "  WARNING: jq not found, skipping $LABEL settings merge"
        echo "  Re-run setup.sh to install jq"
        rm -f "$LOCAL_FILE"
        return
    fi

    if [ -f "$CLOUD_FILE" ]; then
        # 从本地配置中去掉 hooks（云端 hooks 必须保留）
        local LOCAL_NO_HOOKS
        LOCAL_NO_HOOKS=$(jq 'del(.hooks)' "$LOCAL_FILE" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "  WARNING: $LABEL local settings invalid JSON, skipping"
            rm -f "$LOCAL_FILE"
            return
        fi

        # 合并：云端为基础，本地覆盖（hooks 除外）
        if jq -s '.[0] * .[1]' "$CLOUD_FILE" <(echo "$LOCAL_NO_HOOKS") > "${CLOUD_FILE}.tmp" 2>/dev/null; then
            mv "${CLOUD_FILE}.tmp" "$CLOUD_FILE"
            echo "  $LABEL settings.json: merged"
        else
            echo "  WARNING: $LABEL settings merge failed, keeping cloud settings"
            rm -f "${CLOUD_FILE}.tmp"
        fi
    else
        # 云端没有 settings，直接使用本地的（但去掉 hooks）
        mkdir -p "$(dirname "$CLOUD_FILE")"
        jq 'del(.hooks)' "$LOCAL_FILE" > "$CLOUD_FILE" 2>/dev/null
        echo "  $LABEL settings.json: created"
    fi

    rm -f "$LOCAL_FILE"
}

merge_settings "/tmp/local-settings-user.json" "$HOME/.claude/settings.json" "User"

# ---- settings.local.json 合并（权限设置，取并集） ----

merge_settings_local() {
    local LOCAL_FILE="$1"
    local CLOUD_FILE="$2"
    local LABEL="$3"

    if [ ! -f "$LOCAL_FILE" ]; then
        return
    fi

    if ! command -v jq &>/dev/null; then
        echo "  WARNING: jq not found, skipping $LABEL settings.local.json merge"
        rm -f "$LOCAL_FILE"
        return
    fi

    # 验证 JSON 格式
    if ! jq empty "$LOCAL_FILE" 2>/dev/null; then
        echo "  WARNING: $LABEL settings.local.json invalid JSON, skipping"
        rm -f "$LOCAL_FILE"
        return
    fi

    if [ -f "$CLOUD_FILE" ]; then
        # 合并：allow/deny 列表取并集
        if jq -s '{
            permissions: {
                allow: (
                    ([.[0].permissions.allow // []] | flatten) +
                    ([.[1].permissions.allow // []] | flatten)
                ) | unique,
                deny: (
                    ([.[0].permissions.deny // []] | flatten) +
                    ([.[1].permissions.deny // []] | flatten)
                ) | unique
            }
        } | .permissions |= with_entries(select(.value | length > 0))
        ' "$CLOUD_FILE" "$LOCAL_FILE" > "${CLOUD_FILE}.tmp" 2>/dev/null; then
            mv "${CLOUD_FILE}.tmp" "$CLOUD_FILE"
            echo "  $LABEL settings.local.json: merged"
        else
            echo "  WARNING: $LABEL settings.local.json merge failed"
            rm -f "${CLOUD_FILE}.tmp"
        fi
    else
        mkdir -p "$(dirname "$CLOUD_FILE")"
        cp "$LOCAL_FILE" "$CLOUD_FILE"
        echo "  $LABEL settings.local.json: created"
    fi

    rm -f "$LOCAL_FILE"
}

merge_settings_local "/tmp/local-settings-local-user.json" "$HOME/.claude/settings.local.json" "User"

# ============================================================
# 3. Skills 和 Commands 同步
# ============================================================

# 用户级 skills
if [ -d /tmp/local-skills-user ]; then
    mkdir -p "$HOME/.claude/skills"
    cp -r /tmp/local-skills-user/* "$HOME/.claude/skills/" 2>/dev/null
    rm -rf /tmp/local-skills-user
    echo "  User skills: synced"
fi

# 用户级 commands
if [ -d /tmp/local-commands-user ]; then
    mkdir -p "$HOME/.claude/commands"
    cp -r /tmp/local-commands-user/* "$HOME/.claude/commands/" 2>/dev/null
    rm -rf /tmp/local-commands-user
    echo "  User commands: synced"
fi

# ============================================================
# 4. 项目级配置同步
# ============================================================

# 项目级 settings.json
merge_settings "/tmp/local-settings-project.json" "$WORKSPACE/.claude/settings.json" "Project"

# 项目级 settings.local.json（权限设置）
merge_settings_local "/tmp/local-settings-local-project.json" "$WORKSPACE/.claude/settings.local.json" "Project"

# 项目级 skills
if [ -d /tmp/local-skills-project ]; then
    mkdir -p "$WORKSPACE/.claude/skills"
    cp -r /tmp/local-skills-project/* "$WORKSPACE/.claude/skills/" 2>/dev/null
    rm -rf /tmp/local-skills-project
    echo "  Project skills: synced"
fi

# ============================================================
# 5. SSE MCP 自动注册（从本地隧道过来的 MCP 服务）
# ============================================================

if [ -f /tmp/local-sse-mcps.json ]; then
    export PATH="$HOME/.local/bin:$PATH"

    # 清理上次自动注册的 SSE MCP
    for name in $(claude mcp list 2>/dev/null | grep "remote-cc-" | awk '{print $1}'); do
        claude mcp remove "$name" 2>/dev/null || true
    done

    while IFS= read -r mcp_entry; do
        [ -z "$mcp_entry" ] && continue
        mcp_name=$(echo "$mcp_entry" | jq -r '.name')
        mcp_url=$(echo "$mcp_entry" | jq -r '.url')

        cloud_name="remote-cc-${mcp_name}"
        claude mcp remove "$cloud_name" 2>/dev/null || true
        if claude mcp add -t sse -s user -- "$cloud_name" "$mcp_url" 2>/dev/null; then
            echo "  SSE MCP registered: $cloud_name → $mcp_url"
        else
            echo "  WARNING: Failed to register SSE MCP: $cloud_name"
        fi
    done < /tmp/local-sse-mcps.json

    rm -f /tmp/local-sse-mcps.json
fi

# ============================================================
# 6. 生成 ~/workspace/CLAUDE.md（项目级 + Remote CC 上下文）
# ============================================================

CLAUDE_MD="$WORKSPACE/CLAUDE.md"

# 如果有项目级 CLAUDE.md，先写入
if [ -f /tmp/local-claude-project.md ]; then
    cp /tmp/local-claude-project.md "$CLAUDE_MD"
    rm -f /tmp/local-claude-project.md
    echo "  Project CLAUDE.md: synced"
    # 追加分隔线
    cat >> "$CLAUDE_MD" << 'SEPARATOR'

---

SEPARATOR
else
    # 没有项目级 CLAUDE.md，创建空文件
    > "$CLAUDE_MD"
fi

# 追加 Remote CC 环境上下文
cat >> "$CLAUDE_MD" << CLAUDEMD
# Remote CC Environment

You are running in a **cloud relay** environment. Your actual workspace is on the user's **local machine**.

## Current Local Working Directory

\`$LOCAL_DIR\`

This is the user's real working directory on their local Mac. When referencing files, use paths relative to or under this directory.

## Tool Usage Rules

**CRITICAL**: You MUST use \`local__*\` MCP tools for ALL operations. Built-in tools (Read/Edit/Write/Bash/Glob/Grep) are blocked.

| Action           | Use This Tool        | Example Path                |
|------------------|---------------------|-----------------------------|
| Read a file      | \`local__read_file\`  | \`$LOCAL_DIR/src/index.ts\` |
| Edit a file      | \`local__edit_file\`  | \`$LOCAL_DIR/README.md\`    |
| Create a file    | \`local__write_file\` | \`$LOCAL_DIR/new-file.ts\`  |
| Run a command    | \`local__bash\`       | \`ls $LOCAL_DIR/src\`       |
| Find files       | \`local__glob\`       | \`$LOCAL_DIR/**/*.ts\`      |
| Search contents  | \`local__grep\`       | \`$LOCAL_DIR/src\`          |

## Behavior Guidelines

- **All file paths are on the LOCAL machine** at \`$LOCAL_DIR\`
- When the user says "this directory" or "here", they mean \`$LOCAL_DIR\`
- When running shell commands via \`local__bash\`, they execute on the local Mac
- \`local__bash\` uses the local user's normal permissions; treat it like trusted local shell access
- Use \`local__bash\` with \`cd $LOCAL_DIR && ...\` to run commands in the project directory
- When showing file paths to the user, show the local path (e.g. \`$LOCAL_DIR/src/foo.ts\`)
- Do NOT reference \`~/workspace\` or any cloud paths — the user only cares about their local files
- You are effectively working as if you were running locally at \`$LOCAL_DIR\`

## Agent Subagent Guidance

When using the Agent tool to spawn subagents, the subagent also has access to \`local__*\` MCP tools.
**Always include in your agent prompt:**
- "Use local__read_file, local__edit_file, local__write_file, local__bash, local__glob, local__grep for all file operations"
- "All file paths start with $LOCAL_DIR"
- "Do NOT use built-in Read/Edit/Write/Bash/Glob/Grep tools — they are blocked"

## Plan Mode

When in plan mode, use \`local__read_file\` and \`local__grep\` for research.
The \`local__*\` tools are fully capable read-only research tools — treat them exactly like the built-in equivalents.

## Binary File Support

\`local__read_file\` supports images (PNG, JPG, GIF, WebP, SVG, BMP, ICO) — it returns image content directly, just like the built-in Read tool.
For PDF files, it extracts text content automatically (requires poppler).

## Grep Advanced Usage

\`local__grep\` supports the same features as the built-in Grep:
- \`output_mode\`: "content" (matching lines), "files_with_matches" (file paths, default), "count"
- \`context\` / \`before_context\` / \`after_context\`: context lines around matches
- \`type\`: file type filter (e.g. "js", "py", "ts")
- \`multiline\`: cross-line pattern matching
- \`head_limit\`: limit number of results (default 250)
CLAUDEMD

# ============================================================
# 7. Memory 后台同步守护进程
# ============================================================

# 停掉上次残留的同步进程
pkill -f "/opt/remote-cc/memory-sync.sh" 2>/dev/null || true

if [ "$LOCAL_DIR" != "unknown" ] && [ -f /opt/remote-cc/memory-sync.sh ]; then
    BRIDGE_PORT="${BRIDGE_PORT:-3100}"

    # 通过 bridge 动态发现本地 memory 路径（处理 CJK 编码等问题）
    ENCODED_DIR=$(jq -rn --arg v "$LOCAL_DIR" '$v|@uri')
    LOCAL_MEMORY_PATH=$(curl -s --max-time 5 "http://127.0.0.1:${BRIDGE_PORT}/sync/memory-path?workdir=${ENCODED_DIR}" 2>/dev/null | jq -r '.memoryPath // empty' 2>/dev/null)

    CLOUD_MEMORY_PATH="$HOME/.claude/projects/-root-workspace/memory"

    if [ -n "$LOCAL_MEMORY_PATH" ]; then
        mkdir -p "$CLOUD_MEMORY_PATH"
        nohup /opt/remote-cc/memory-sync.sh \
            "$LOCAL_MEMORY_PATH" \
            "$CLOUD_MEMORY_PATH" \
            "$BRIDGE_PORT" \
            30 \
            > /tmp/memory-sync.log 2>&1 &
        echo "  Memory sync: started (PID $!, interval 30s)"
    else
        echo "  Memory sync: skipped (local memory path not found)"
    fi
fi

echo "  Session prepared: local dir = $LOCAL_DIR"
