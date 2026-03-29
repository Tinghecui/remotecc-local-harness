# Remote CC

在云端 VPS 运行 Claude Code，所有文件操作和命令在你本地机器上执行，通过 SSH 反向隧道连接。

## 为什么？

- Claude Code 对网络、CPU、内存要求高，本地跑容易卡
- 云端 VPS 便宜且性能好，但文件在本地
- Remote CC 让云端 Claude Code 透明地操作你的本地文件

## 架构

```
你的 Mac (本地)                          云端 VPS
┌──────────────────┐                ┌──────────────────┐
│ Terminal 1       │                │                  │
│ MCP Bridge :3100 │◄── SSH 隧道 ───│ Claude Code      │
│  ├ read_file     │                │  内置 tool 被    │
│  ├ edit_file     │                │  Hook 拦截       │
│  ├ write_file    │                │  ↓               │
│  ├ bash          │                │  改用 MCP tool   │
│  ├ glob          │                │  ↓               │
│  └ grep          │                │  请求发到 Bridge  │
│                  │                │                  │
│ Terminal 2       │    SSH -R      │                  │
│ connect.sh ─────────────────────→│ claude           │
└──────────────────┘                └──────────────────┘
```

1. 本地运行 MCP Bridge，提供 6 个文件/命令工具
2. SSH 反向隧道让云端 `localhost:3100` 指向你本地的 Bridge
3. 云端 Claude Code 的内置工具被 Hook 拦截，强制使用 MCP 工具
4. MCP 请求通过隧道回到本地执行，结果原路返回

## 快速开始

### 前置条件

- 本地：macOS/Linux，Node.js 20+
- 云端：Ubuntu 22/24 VPS，1G+ 内存
- SSH 免密登录：`ssh-copy-id root@<VPS_IP>`

### 1. 配置

```bash
git clone <repo-url> remote-cc
cd remote-cc

# 创建配置文件
cp .remote-cc.env.example .remote-cc.env
# 编辑 .remote-cc.env，填入你的 VPS 地址
```

`.remote-cc.env` 示例：
```bash
REMOTE_CC_HOST=root@your-vps-ip
REMOTE_CC_PORT=3100
REMOTE_CC_ROOTS=~/projects,~/Desktop
```

所有脚本都会自动读取这个文件，配置一次即可。也可以通过命令行参数覆盖。

### 2. 一键部署

```bash
# 使用配置文件中的 REMOTE_CC_HOST
./setup.sh

# 或直接指定
./setup.sh root@<VPS_IP>
```

### 3. 日常使用

```bash
# 终端 1：启动本地 Bridge（保持运行）
./scripts/start-bridge.sh

# 终端 2：连接云端（在你要操作的项目目录下执行）
cd ~/my-project
./scripts/connect.sh
```

多开终端重复步骤 2 即可并行多个 Claude Code 会话，共享同一个 Bridge。

## 项目结构

```
remote-cc/
├── local-bridge/            # 本地 MCP Bridge Server (TypeScript)
│   └── src/
│       ├── index.ts         # HTTP + SSE 入口
│       ├── server.ts        # MCP 工具定义（6 个工具）
│       ├── security.ts      # 路径白名单 + 命令黑名单
│       └── config.ts        # 环境变量配置
├── cloud-setup/             # 云端部署文件
│   ├── install.sh           # 云端安装脚本
│   ├── prepare-session.sh   # 每次连接时动态生成配置
│   ├── hooks/
│   │   └── block-builtin.sh # PreToolUse Hook：拦截内置工具
│   └── claude-config/
│       ├── settings.json    # Hook 配置
│       └── CLAUDE.md        # 引导 Claude 使用 MCP 工具
├── scripts/                 # 便捷脚本
│   ├── start-bridge.sh      # 启动本地 Bridge
│   ├── connect.sh           # SSH 连接云端 + 启动 claude
│   └── status.sh            # 检查各组件状态
└── setup.sh                 # 一键部署入口
```

## 配置

### 环境变量（本地 Bridge）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MCP_ALLOWED_ROOTS` | `~/projects` | 允许访问的目录（逗号分隔） |
| `MCP_PORT` | `3100` | Bridge 监听端口 |
| `MCP_CMD_TIMEOUT` | `120000` | 命令超时（毫秒） |
| `MCP_LOG` | `true` | 设为 `false` 关闭请求日志 |

### 自定义允许目录

```bash
# 启动时指定
./scripts/start-bridge.sh ~/projects,~/work,~/Documents

# 或通过环境变量
MCP_ALLOWED_ROOTS="~/projects,~/work" ./scripts/start-bridge.sh
```

### 自定义端口

```bash
MCP_PORT=4100 ./scripts/start-bridge.sh
./scripts/connect.sh root@<VPS_IP> 4100
```

## 连接时自动同步

每次 `connect.sh` 连接时，自动将以下本地配置上传到云端：

| 本地文件 | 说明 |
|---------|------|
| `~/.claude/CLAUDE.md` | 用户级指令 |
| `项目/CLAUDE.md` | 项目级指令 |
| `~/.claude/settings.json` | 用户偏好（合并，保留云端 hooks） |
| `~/.claude/skills/` | 个人 skills |
| `~/.claude/commands/` | 自定义命令 |

## 安全

- MCP Bridge **只监听 localhost**，不暴露到公网
- 所有流量通过 **SSH 加密隧道**传输
- Bridge 有**路径白名单**，只能访问指定目录
- Bridge 有**命令黑名单**，拦截危险命令

## 故障排查

```bash
# 检查各组件状态
./scripts/status.sh <VPS_IP>

# Bridge 端口被占用
lsof -ti:3100 | xargs kill -9

# 确认 Bridge 正常
curl http://localhost:3100/health

# 确认隧道通畅（在 VPS 上执行）
curl http://localhost:3100/health

# 重启会话
# 在 claude 里输入 /exit，然后重新 connect.sh
```

## License

MIT
