#!/bin/bash
# PreToolUse Hook: 拦截 Claude Code 内置 tool，强制使用 MCP tool
# 当 Claude Code 尝试使用 Read/Edit/Write/Bash/Glob/Grep 时，
# 此脚本返回非零退出码，阻止执行并提示使用 MCP 替代工具。

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
