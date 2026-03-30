#!/bin/bash
# ============================================================
# 每次 connect.sh 连接时在云端执行
# 同步本地配置到云端，动态生成会话级 workspace / CLAUDE.md / .mcp.json
#
# 从 REMOTE_CC_SESSION_TMP 读取 connect.sh 上传的文件：
#   local-claude-user.md            → ~/.claude/CLAUDE.md
#   local-claude-project.md         → ~/workspace/<session>/CLAUDE.md
#   local-settings-user.json        → merge into ~/.claude/settings.json
#   local-settings-project.json     → merge into ~/workspace/<session>/.claude/settings.json
#   local-skills-user/              → ~/.claude/skills/
#   local-commands-user/            → ~/.claude/commands/
#   local-skills-project/           → ~/workspace/<session>/.claude/skills/
#   local-commands-project/         → ~/workspace/<session>/.claude/commands/
#   local-sse-mcps.json             → ~/workspace/<session>/.mcp.json
#
# 环境变量:
#   REMOTE_CC_LOCAL_DIR      — 本地工作目录路径
#   REMOTE_CC_SESSION_ID     — connect.sh 生成的会话 ID
#   REMOTE_CC_SESSION_TMP    — 本次会话的云端暂存目录
#   REMOTE_CC_WORKSPACE_NAME — 会话级 workspace 目录名
#   BRIDGE_PORT              — 本会话反向隧道后的远端 bridge 端口
# ============================================================

LOCAL_DIR="${REMOTE_CC_LOCAL_DIR:-unknown}"
SESSION_ID="${REMOTE_CC_SESSION_ID:-default}"
SESSION_TMP="${REMOTE_CC_SESSION_TMP:-/tmp/remote-cc-session}"
WORKSPACE_NAME="${REMOTE_CC_WORKSPACE_NAME:-default}"
WORKSPACE="$HOME/workspace/$WORKSPACE_NAME"
BRIDGE_PORT="${BRIDGE_PORT:-3100}"

mkdir -p "$SESSION_TMP"
mkdir -p "$WORKSPACE"

session_file() {
    printf '%s/%s' "$SESSION_TMP" "$1"
}

SESSION_USER_CLAUDE="$(session_file "local-claude-user.md")"
SESSION_PROJECT_CLAUDE="$(session_file "local-claude-project.md")"
SESSION_SETTINGS_USER="$(session_file "local-settings-user.json")"
SESSION_SETTINGS_LOCAL_USER="$(session_file "local-settings-local-user.json")"
SESSION_SKILLS_USER="$(session_file "local-skills-user")"
SESSION_COMMANDS_USER="$(session_file "local-commands-user")"
SESSION_SETTINGS_PROJECT="$(session_file "local-settings-project.json")"
SESSION_SETTINGS_LOCAL_PROJECT="$(session_file "local-settings-local-project.json")"
SESSION_SKILLS_PROJECT="$(session_file "local-skills-project")"
SESSION_COMMANDS_PROJECT="$(session_file "local-commands-project")"
SESSION_SSE_MCP_LIST="$(session_file "local-sse-mcps.json")"
SESSION_MEMORY_PID_FILE="$(session_file "memory-sync.pid")"
SESSION_MEMORY_LOG="$(session_file "memory-sync.log")"

# ============================================================
# 1. CLAUDE.md 同步
# ============================================================

# 用户级 CLAUDE.md
if [ -f "$SESSION_USER_CLAUDE" ]; then
    mkdir -p "$HOME/.claude"
    cp "$SESSION_USER_CLAUDE" "$HOME/.claude/CLAUDE.md"
    rm -f "$SESSION_USER_CLAUDE"
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

merge_settings "$SESSION_SETTINGS_USER" "$HOME/.claude/settings.json" "User"

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

merge_settings_local "$SESSION_SETTINGS_LOCAL_USER" "$HOME/.claude/settings.local.json" "User"

# ============================================================
# 3. Skills 和 Commands 同步
# ============================================================

# 用户级 skills
if [ -d "$SESSION_SKILLS_USER" ]; then
    mkdir -p "$HOME/.claude/skills"
    cp -r "$SESSION_SKILLS_USER"/* "$HOME/.claude/skills/" 2>/dev/null
    rm -rf "$SESSION_SKILLS_USER"
    echo "  User skills: synced"
fi

# 用户级 commands
if [ -d "$SESSION_COMMANDS_USER" ]; then
    mkdir -p "$HOME/.claude/commands"
    cp -r "$SESSION_COMMANDS_USER"/* "$HOME/.claude/commands/" 2>/dev/null
    rm -rf "$SESSION_COMMANDS_USER"
    echo "  User commands: synced"
fi

# ============================================================
# 4. 项目级配置同步
# ============================================================

# 项目级 settings.json
merge_settings "$SESSION_SETTINGS_PROJECT" "$WORKSPACE/.claude/settings.json" "Project"

# 项目级 settings.local.json（权限设置）
merge_settings_local "$SESSION_SETTINGS_LOCAL_PROJECT" "$WORKSPACE/.claude/settings.local.json" "Project"

# 项目级 skills
if [ -d "$SESSION_SKILLS_PROJECT" ]; then
    mkdir -p "$WORKSPACE/.claude/skills"
    cp -r "$SESSION_SKILLS_PROJECT"/* "$WORKSPACE/.claude/skills/" 2>/dev/null
    rm -rf "$SESSION_SKILLS_PROJECT"
    echo "  Project skills: synced"
fi

# 项目级 commands
if [ -d "$SESSION_COMMANDS_PROJECT" ]; then
    mkdir -p "$WORKSPACE/.claude/commands"
    cp -r "$SESSION_COMMANDS_PROJECT"/* "$WORKSPACE/.claude/commands/" 2>/dev/null
    rm -rf "$SESSION_COMMANDS_PROJECT"
    echo "  Project commands: synced"
fi

# ============================================================
# 5. 生成会话级 .mcp.json
# ============================================================

generate_project_mcp_config() {
    local bridge_url
    local mcp_json

    if ! command -v jq &>/dev/null; then
        echo "  WARNING: jq not found, skipping project .mcp.json generation"
        rm -f "$SESSION_SSE_MCP_LIST"
        return
    fi

    bridge_url="http://127.0.0.1:${BRIDGE_PORT}/sse"
    mcp_json=$(jq -n --arg url "$bridge_url" '{
        mcpServers: {
            "local-bridge": {
                type: "sse",
                url: $url
            }
        }
    }')

    if [ -f "$SESSION_SSE_MCP_LIST" ]; then
        while IFS= read -r mcp_entry; do
            [ -z "$mcp_entry" ] && continue
            mcp_name=$(echo "$mcp_entry" | jq -r '.name // empty')
            mcp_url=$(echo "$mcp_entry" | jq -r '.url // empty')

            if [ -z "$mcp_name" ] || [ -z "$mcp_url" ]; then
                continue
            fi

            cloud_name="remote-cc-${mcp_name}"
            mcp_json=$(echo "$mcp_json" | jq --arg name "$cloud_name" --arg url "$mcp_url" '
                .mcpServers[$name] = {
                    type: "sse",
                    url: $url
                }
            ')
            echo "  Project MCP: $cloud_name → $mcp_url"
        done < "$SESSION_SSE_MCP_LIST"
        rm -f "$SESSION_SSE_MCP_LIST"
    fi

    printf '%s\n' "$mcp_json" > "$WORKSPACE/.mcp.json"
    echo "  Project MCP: wrote $WORKSPACE/.mcp.json"
}

generate_project_mcp_config

# ============================================================
# 6. 生成会话级 CLAUDE.md（项目级 + Remote CC 上下文）
# ============================================================

CLAUDE_MD="$WORKSPACE/CLAUDE.md"

# 如果有项目级 CLAUDE.md，先写入
if [ -f "$SESSION_PROJECT_CLAUDE" ]; then
    cp "$SESSION_PROJECT_CLAUDE" "$CLAUDE_MD"
    rm -f "$SESSION_PROJECT_CLAUDE"
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

## Cloud-Side Files (Plans, Memory, Tasks)

Plans, memory, and task files live on the **cloud VPS** under \`~/.claude/\`. For these files:
- **Use built-in Read/Write/Edit tools** (they are NOT blocked for \`~/.claude/*\` paths)
- Do NOT use \`local__*\` MCP tools for cloud paths — they operate on the local Mac filesystem
- Examples of cloud paths: \`/root/.claude/plans/\`, \`/root/.claude/projects/.../memory/\`

When spawning Plan or other subagents that need to write plans/memory, do NOT include "use local__* tools" instructions for cloud-side file operations.

## Plan Mode

When in plan mode, use \`local__read_file\` and \`local__grep\` for research on LOCAL files.
Use built-in Read/Glob/Grep for cloud-side files (\`~/.claude/*\`, \`~/workspace/*\`).
The \`local__*\` tools are fully capable read-only research tools — treat them exactly like the built-in equivalents for local files.

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
# 7. Memory 后台同步守护进程（按会话隔离）
# ============================================================

if [ -f "$SESSION_MEMORY_PID_FILE" ]; then
    OLD_SYNC_PID=$(cat "$SESSION_MEMORY_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_SYNC_PID" ] && kill -0 "$OLD_SYNC_PID" 2>/dev/null; then
        kill "$OLD_SYNC_PID" 2>/dev/null || true
    fi
    rm -f "$SESSION_MEMORY_PID_FILE"
fi

if [ "$LOCAL_DIR" != "unknown" ] && [ -f /opt/remote-cc/memory-sync.sh ]; then
    # 通过 bridge 动态发现本地 memory 路径（处理 CJK 编码等问题）
    ENCODED_DIR=$(jq -rn --arg v "$LOCAL_DIR" '$v|@uri')
    LOCAL_MEMORY_PATH=$(curl -s --max-time 5 "http://127.0.0.1:${BRIDGE_PORT}/sync/memory-path?workdir=${ENCODED_DIR}" 2>/dev/null | jq -r '.memoryPath // empty' 2>/dev/null)

    WORKSPACE_PROJECT_KEY=$(printf '%s' "$WORKSPACE" | sed 's#/#-#g')
    CLOUD_MEMORY_PATH="$HOME/.claude/projects/${WORKSPACE_PROJECT_KEY}/memory"

    if [ -n "$LOCAL_MEMORY_PATH" ]; then
        mkdir -p "$CLOUD_MEMORY_PATH"
        nohup /opt/remote-cc/memory-sync.sh \
            "$LOCAL_MEMORY_PATH" \
            "$CLOUD_MEMORY_PATH" \
            "$BRIDGE_PORT" \
            30 \
            > "$SESSION_MEMORY_LOG" 2>&1 &
        echo "$!" > "$SESSION_MEMORY_PID_FILE"
        echo "  Memory sync: started (PID $!, interval 30s)"
    else
        echo "  Memory sync: skipped (local memory path not found)"
    fi
fi

echo "  Session prepared: $SESSION_ID → $WORKSPACE"
