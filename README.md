# Remote CC

在云端 VPS 运行 Claude Code，但把文件读写和命令执行留在你本地机器上，通过 SSH 反向隧道把两边接起来。

> 状态：`alpha`。已经适合自用和分享给熟悉 Claude Code 的开发者，但仍建议把它当作“可信环境里的本地自动化桥”来使用。

## 它解决什么问题

- Claude Code 很吃网络、CPU、内存，本地跑会卡。
- 便宜的 VPS 跑 Claude Code 很轻松，但你的源码和工作环境还在本地。
- Remote CC 让 Claude 跑在云端，同时透明地操作你本地的项目目录。

## 工作方式

```text
你的 Mac / Linux（本地）                  云端 VPS
┌────────────────────┐                 ┌──────────────────┐
│ Terminal 1         │                 │                  │
│ local-bridge :3100 │◄── SSH -R ─────│ Claude Code      │
│  ├ read_file       │                 │  内置工具被 Hook  │
│  ├ edit_file       │                 │  拦截后改走 MCP    │
│  ├ write_file      │                 │                  │
│  ├ bash            │                 │                  │
│  ├ glob            │                 │                  │
│  └ grep            │                 │                  │
│                    │                 │                  │
│ Terminal 2         │                 │                  │
│ connect.sh         │────────────────▶│ claude           │
└────────────────────┘                 └──────────────────┘
```

链路分成 4 步：

1. 本地启动 `local-bridge`，提供 6 个 MCP 工具。
2. `connect.sh` 为每个会话单独分配一组云端回环端口，并通过 SSH 反向隧道把它们接回本地 bridge / MCP。
3. 云端 Claude Code 的内置 Read/Edit/Write/Bash/Glob/Grep 被 hook 拦截。
4. Claude 改走 `local__*` MCP 工具，请求通过隧道回到你本地执行。

## 快速开始

### 前置条件

- 本地：macOS 或 Linux，Node.js 20+
- 云端：Ubuntu 22/24
- 已配置 SSH 免密登录：`ssh-copy-id root@<VPS_IP>`

### 1. 一次命令安装

只安装本地 CLI：

```bash
curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | bash
```

安装并直接完成配置 + 部署：

```bash
curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | \
  bash -s -- \
    --host root@<VPS_IP> \
    --ssh-port 22 \
    --bridge-port 3100 \
    --roots "$HOME/projects,$HOME/Desktop"
```

如果你已经装过，只想重新走一次线上 installer 并按现有配置重新部署：

```bash
curl -fsSL https://raw.githubusercontent.com/Tinghecui/remotecc-local-harness/main/install.sh | \
  bash -s -- --deploy
```

### 2. 手动配置

```bash
git clone <repo-url> remote-cc
cd remote-cc
cp .remote-cc.env.example .remote-cc.env
```

示例：

```bash
REMOTE_CC_HOST=root@your-vps-ip
REMOTE_CC_PORT=3100
REMOTE_CC_ROOTS=~/projects,~/Desktop
MCP_HOST=127.0.0.1
```

或者安装完 CLI 之后直接运行交互向导：

```bash
ccc setup
```

### 3. 一键部署到云端

```bash
./setup.sh

# 或者直接指定
./setup.sh root@<VPS_IP>
```

`setup.sh` 会完成：

- 本地 `local-bridge` 依赖安装
- 云端 Claude Code 安装
- hook / MCP / `prepare-session.sh` / `memory-sync.sh` 配置
- 一次本地到云端的链路验证

### 4. 日常使用

```bash
# 终端 1：启动本地 bridge
./scripts/start-bridge.sh

# 终端 2：进入你要工作的项目目录，再连接云端
cd ~/my-project
./scripts/connect.sh
```

如果你想重复进入同一个项目，`connect.sh` 默认会复用该项目的云端 workspace，这样 Claude 的 `-c` / `/resume` 更稳定。

如果你想并行多个彼此隔离的 Claude 会话，可以临时切到独立 workspace 模式：

```bash
REMOTE_CC_WORKSPACE_MODE=session ./scripts/connect.sh
```

## 项目结构

```text
remote-cc/
├── local-bridge/            # 本地 MCP Bridge Server (TypeScript)
│   ├── src/
│   │   ├── index.ts         # HTTP + SSE 入口
│   │   ├── server.ts        # MCP 工具定义（6 个工具）
│   │   ├── security.ts      # 路径边界判断 + 命令黑名单
│   │   └── config.ts        # 环境变量配置
│   └── test/
│       └── security.test.ts # 最小安全回归测试
├── cloud-setup/             # 云端部署文件
│   ├── install.sh           # 云端安装脚本
│   ├── prepare-session.sh   # 每次连接时动态准备会话级 workspace / .mcp.json
│   ├── memory-sync.sh       # Claude memory 同步守护进程
│   ├── hooks/
│   │   └── block-builtin.sh # 拦截内置工具
│   └── claude-config/
│       ├── settings.json    # Hook 配置
│       └── CLAUDE.md        # 引导 Claude 使用 MCP 工具
├── scripts/
│   ├── start-bridge.sh      # 启动本地 bridge
│   ├── connect.sh           # 建立反向隧道并启动云端 claude
│   └── status.sh            # 本地 / 云端状态检查
└── setup.sh                 # 主入口：一键部署
```

## 配置项

### 本地 bridge 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MCP_HOST` | `127.0.0.1` | 监听地址，默认只绑定回环地址 |
| `MCP_ALLOWED_ROOTS` | `~/Desktop, ~/projects, ~/Documents` 中存在的目录 | 文件类工具允许访问的目录 |
| `MCP_PORT` | `3100` | Bridge 监听端口 |
| `MCP_CMD_TIMEOUT` | `120000` | 命令超时（毫秒） |
| `MCP_LOG` | `true` | 设为 `false` 关闭请求日志 |

### connect.sh 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REMOTE_CC_REMOTE_PORT_START` | `43000` | 云端会话专用反向端口的起始范围 |
| `REMOTE_CC_REMOTE_PORT_END` | `48999` | 云端会话专用反向端口的结束范围 |
| `REMOTE_CC_WORKSPACE_MODE` | `project` | `project` 复用同一项目 workspace，`session` 为每次连接创建独立 workspace |

### 自定义允许目录

```bash
./scripts/start-bridge.sh ~/projects,~/work,~/Documents

# 或通过环境变量
MCP_ALLOWED_ROOTS="~/projects,~/work" ./scripts/start-bridge.sh
```

### 自定义端口

```bash
MCP_PORT=4100 ./scripts/start-bridge.sh
./scripts/connect.sh root@<VPS_IP> 4100
```

## 连接时会同步什么

每次运行 `connect.sh` 时，会自动把下面这些本地配置带到云端：

| 本地文件 | 说明 |
|---------|------|
| `~/.claude/CLAUDE.md` | 用户级指令 |
| `项目/CLAUDE.md` | 项目级指令 |
| `~/.claude/settings.json` | 用户偏好，合并时保留云端 hooks |
| `~/.claude/settings.local.json` | 权限设置，按 allow/deny 并集合并 |
| `~/.claude/skills/` | 用户级 skills |
| `~/.claude/commands/` | 用户级 commands |
| `项目/.claude/skills/` | 项目级 skills |

## 安全模型

- bridge 默认只绑定 `127.0.0.1`，不直接暴露到公网。
- 所有流量通过 SSH 反向隧道传输，云端只访问到回环地址上的 MCP 服务。
- `read_file`、`edit_file`、`write_file`、`glob`、`grep` 这些文件类工具会强制限制在 `MCP_ALLOWED_ROOTS` 之内。
- `bash` 会从允许目录里的工作目录启动，但它不是容器或沙箱，仍然以你本地用户权限执行 shell 命令。
- 所以更准确的使用假设是：你信任这次 Claude 会话，也信任连接到的 VPS。

## 已知限制

- 文件类工具要求绝对路径。
- `bash` 只有黑名单保护，不会对所有危险命令做完备拦截。
- 当前主要验证过的组合是：本地 macOS/Linux + 云端 Ubuntu 22/24。

## 开发验证

```bash
cd local-bridge
npm install
npm run check
```

## 故障排查

```bash
# 查看整体状态
./scripts/status.sh <VPS_IP>

# 查看本地 bridge 是否已经监听
lsof -nP -iTCP:3100 -sTCP:LISTEN

# 本地健康检查
curl http://127.0.0.1:3100/health

# 云端通过反向隧道访问 bridge（在 VPS 上执行）
curl http://127.0.0.1:3100/health

# 重启会话
# 在 claude 里输入 /exit，然后重新 ./scripts/connect.sh
```

## License

MIT
