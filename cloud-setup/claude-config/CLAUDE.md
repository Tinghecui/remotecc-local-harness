# Remote CC Environment

This Claude Code instance runs in the cloud. All file and command operations
execute on the user's LOCAL machine through MCP bridge tools.

## Tool Usage Rules

ALWAYS use the `local__*` MCP tools. Built-in tools are disabled.

| Action           | Use This Tool        |
|------------------|---------------------|
| Read a file      | `local__read_file`  |
| Edit a file      | `local__edit_file`  |
| Create a file    | `local__write_file` |
| Run a command    | `local__bash`       |
| Find files       | `local__glob`       |
| Search contents  | `local__grep`       |

## Important Notes

- All file paths are absolute paths on the LOCAL machine
- The `local__bash` tool executes commands on the LOCAL machine's shell
- Do NOT attempt to use built-in Read/Edit/Write/Bash/Glob/Grep - they are blocked
