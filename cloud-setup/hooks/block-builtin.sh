#!/bin/bash
# PreToolUse Hook: 拦截 Claude Code 内置 tool，强制使用 MCP tool
# 对 ~/.claude/ 路径放行（plans、memory、settings 等需要云端本地读写）
# 其余操作全部拦截，强制走 MCP

INPUT=$(cat)

# 提取 file_path（Read/Edit/Write 工具会带这个字段）
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# 如果是对 ~/.claude/ 路径的操作，放行
if [ -n "$FILE_PATH" ]; then
    CLAUDE_DIR="$HOME/.claude"
    case "$FILE_PATH" in
        "$CLAUDE_DIR"/*|"$HOME"/workspace/*/CLAUDE.md|"$HOME"/workspace/*/.mcp.json|"$HOME"/workspace/*/.claude/*)
            exit 0
            ;;
    esac
fi

LOCAL_DIR="${REMOTE_CC_LOCAL_DIR:-unknown}"

# 提取工具名称
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)

cat << EOF
BLOCKED: Built-in "$TOOL_NAME" is disabled — use MCP equivalent instead.

  Read   → local__read_file   (supports images & PDF)
  Edit   → local__edit_file
  Write  → local__write_file
  Bash   → local__bash        (runs on local Mac)
  Glob   → local__glob
  Grep   → local__grep        (supports output_mode, context, type)

All paths must start with: $LOCAL_DIR

Exception: Plans and memory files are written to cloud (~/.claude/*) using built-in tools.
EOF
exit 2
