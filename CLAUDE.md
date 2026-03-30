# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
cd local-bridge && npm install        # 安装依赖
cd local-bridge && npm test           # 运行最小安全测试
cd local-bridge && npm run check      # build + test
cd local-bridge && npm run build       # 编译 TypeScript
cd local-bridge && npx tsx src/index.ts  # 开发模式运行

./setup.sh root@<VPS_IP>              # 一键部署
./scripts/start-bridge.sh             # 启动本地 Bridge
./scripts/connect.sh root@<VPS_IP>    # 连接云端
```

## Architecture

SSH reverse tunnel connects a local MCP Bridge to cloud Claude Code:

- **local-bridge/** — TypeScript MCP server (Express + SSE). Exposes 6 tools (`read_file`, `edit_file`, `write_file`, `bash`, `glob`, `grep`) on the local filesystem. File-style tools are root-scoped; `bash` still runs with the local user's normal permissions.
- **cloud-setup/** — VPS deployment files. PreToolUse hook (`block-builtin.sh`, exit code 2) blocks built-in tools, forcing Claude to use MCP tools. MCP registered as SSE via `claude mcp add`.
- **scripts/** — `connect.sh` builds SSH reverse tunnel + syncs config + launches claude. `start-bridge.sh` runs the local bridge. `prepare-session.sh` generates `~/workspace/CLAUDE.md` on VPS.
- **`.remote-cc.env`** — User config file (gitignored). All scripts read from it. See `.remote-cc.env.example`.

## Key Design Decisions

- **SSE transport, not HTTP Streamable** — Claude Code's HTTP MCP client forces OAuth flow. SSE avoids this.
- **No auth layer** — Security relies on the SSH tunnel. Bridge binds to `127.0.0.1` by default.
- **Hook format** — `{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}` (nested `hooks` array).
- **MCP via CLI** — `claude mcp add -t sse -s user -- name url` writes to `~/.claude.json`. Hooks go in `settings.json`.
- **Config sync** — `connect.sh` uploads local CLAUDE.md, settings.json, skills/, commands/ on each connection. `prepare-session.sh` merges them (preserving cloud hooks).
