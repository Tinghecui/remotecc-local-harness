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
        "$CLAUDE_DIR"/*|"$HOME/workspace/CLAUDE.md")
            exit 0
            ;;
    esac
fi

cat << 'EOF'
DENIED: Built-in tools are disabled in this cloud environment.
All file operations and commands must execute on the local machine via MCP.

Use these MCP tools instead:
  local__read_file   → Read a file
  local__edit_file   → Edit a file
  local__write_file  → Create/overwrite a file
  local__bash        → Execute a shell command
  local__glob        → Find files by pattern
  local__grep        → Search file contents
EOF
exit 2
