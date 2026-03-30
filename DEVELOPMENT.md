# Remote CC Development Plan

本文件用于记录项目的内部开发路线，尤其是 Windows 支持的设计原则、任务拆解、验收标准与迭代顺序。

最后更新：2026-03-30

## 1. 背景与目标

当前项目的核心链路已经成立：

- 本地运行 `local-bridge`
- 通过 `ssh -R` 把本地 MCP SSE 服务反向映射到 VPS
- 云端 Claude Code 通过 Hook 被强制走 `local__*` MCP 工具

这条链路对 Linux / macOS 已经基本可用。后续的 Windows 支持，不应被设计成一套独立版本，而应作为同一项目中的平台适配能力。

### 核心目标

- 保持 VPS 侧结构基本不变
- 保持 Linux / macOS 当前使用方式不回退
- 增加 Windows 本地运行能力
- 避免维护两套完整实现
- 让未来的新功能默认只改一套共享逻辑

### 非目标

- 不做单独的 Windows 分叉仓库
- 不长期维护一套完整 `.sh` 与一套完整 `.ps1` 的双份业务逻辑
- 不在第一阶段修改云端整体架构

## 2. 当前结论

### Linux / macOS

Linux / macOS 现有代码结构总体可继续使用，问题不大，后续主要是从 shell 脚本迁移到跨平台 CLI，以减少平台耦合。

### Windows

Windows 的难点主要在本地侧，不在 VPS 侧。真正需要适配的是：

- 本地入口脚本
- 本地 shell 执行模型
- 路径与默认目录
- 端口检测方式
- `ssh` / `scp` 启动方式
- 配置文件路径和本地工具发现方式

### 维护原则

未来如果继续新增功能：

- 共享业务流程改一处
- 平台差异只改平台适配层
- 不允许新功能直接写死到 Linux shell 脚本里

## 3. 开发原则

### 3.1 单一主线

Windows 不是“额外版本”，而是“同一产品的一种本地运行平台”。

### 3.2 平台差异收口

平台差异必须集中在单独模块，不允许散落在：

- `connect` 业务逻辑
- `setup` 业务逻辑
- `start` 业务逻辑
- MCP 工具实现内部

### 3.3 云端优先稳定

以下部分原则上保持稳定，除非 Windows 适配被它们阻塞：

- `cloud-setup/install.sh`
- `cloud-setup/prepare-session.sh`
- `cloud-setup/hooks/block-builtin.sh`
- VPS 上的 Claude Code + Hook + MCP 配置方式

### 3.4 首版先求稳，再求“纯 Windows 风格”

Windows 首版优先做“可稳定跑通”，不在第一阶段追求：

- 单文件打包
- 图形界面
- 完整 PowerShell-only 体验

## 4. 目标架构

建议将本地侧拆成三层：

### 4.1 共享核心层

负责：

- 配置读取
- 文件同步流程
- SSH 参数拼装
- SSE MCP 自动隧道逻辑
- 本地 bridge 启动流程
- 状态检查流程

### 4.2 平台适配层

负责：

- 默认工作目录
- shell 后端选择
- 端口占用检查
- `ssh` / `scp` 二进制发现
- 本地 Claude 配置路径
- 危险命令黑名单

### 4.3 薄入口层

负责：

- CLI 子命令入口
- 参数解析
- 帮助信息输出

## 5. 建议目录改造

建议新增本地 CLI，而不是继续把核心逻辑放在 shell 脚本里：

```text
local-cli/
├── src/
│   ├── index.ts
│   ├── commands/
│   │   ├── start.ts
│   │   ├── connect.ts
│   │   ├── status.ts
│   │   └── setup.ts
│   ├── lib/
│   │   ├── env.ts
│   │   ├── ssh.ts
│   │   ├── scp.ts
│   │   ├── ports.ts
│   │   ├── claude-config.ts
│   │   └── sse-mcp.ts
│   └── platform/
│       ├── detect.ts
│       ├── unix.ts
│       └── windows.ts
```

### 脚本迁移策略

- 保留现有 `scripts/*.sh` 作为兼容入口一段时间
- shell 脚本逐步变成 Node CLI 的薄包装
- 等 CLI 稳定后，再决定是否彻底移除旧脚本

## 6. 里程碑

### M1：跨平台结构定型

目标：

- 本地逻辑迁移到共享 CLI
- Linux / macOS 不回退
- 平台差异有明确边界

### M2：Windows MVP 跑通

目标：

- Windows 本地可启动 bridge
- Windows 本地可连接 VPS
- 云端 Claude 可读写 Windows 本地项目

### M3：稳定性补齐

目标：

- 跨平台测试补齐
- 文档补齐
- 中英文路径、空格路径、断线重连验证完成

### M4：增强功能

目标：

- 可选 PowerShell 模式
- 更好的 Windows 分发方式

## 7. 总任务表

| ID | 优先级 | 任务 | 目标 |
|---|---|---|---|
| T01 | 高 | 确定共享核心 + 平台适配架构 | 避免双份维护 |
| T02 | 高 | 设计 Node CLI 命令模型 | 统一本地入口 |
| T03 | 高 | 设计平台适配接口 | 收口平台差异 |
| T04 | 高 | 迁移 `start-bridge` | 跨平台启动本地 bridge |
| T05 | 高 | 迁移 `status` | 跨平台状态检查 |
| T06 | 高 | 迁移 `connect` | 跨平台连接与同步 |
| T07 | 中 | 迁移 `setup` | 跨平台一键部署 |
| T08 | 高 | `local__bash` 平台抽象 | 支持 Windows shell 后端 |
| T09 | 高 | Windows 路径与默认目录适配 | 解决盘符与目录差异 |
| T10 | 高 | Windows 危险命令黑名单 | 补安全边界 |
| T11 | 中 | 云端提示文案平台中立化 | 避免误导 Claude |
| T12 | 高 | Windows MVP 联调 | 跑通端到端链路 |
| T13 | 高 | 补跨平台测试 | 防回归 |
| T14 | 中 | 补 Windows 文档 | 降低接入门槛 |
| T15 | 中 | PowerShell 模式 | 做可选增强 |
| T16 | 低 | Windows 安装分发 | 优化体验 |

## 8. 详细任务拆解

### T01 确定共享核心 + 平台适配架构

目标：

- 后续功能默认只改共享核心
- 不维护完整双份脚本

具体工作：

- 确认本地入口未来统一由 Node CLI 管理
- 确认 shell 脚本不再承载复杂业务逻辑
- 确认平台差异只存在于 `platform/*`

产出：

- 本开发文档中的架构方案
- 后续文件布局基线

验收标准：

- 能明确说出“新功能加在哪里”
- 团队后续不再计划写一整套 `.ps1` 克隆版

### T02 设计 Node CLI 命令模型

目标：

- 统一 `start` / `connect` / `status` / `setup`

建议命令：

- `remote-cc start`
- `remote-cc connect`
- `remote-cc status`
- `remote-cc setup`

建议参数：

- `--host`
- `--port`
- `--roots`
- `--workdir`
- `--shell-backend`
- `--config`

具体工作：

- 设计参数优先级：CLI > 环境变量 > `.remote-cc.env` > 默认值
- 明确每个命令的输出格式和错误码

验收标准：

- 现有四个脚本都能映射成 CLI 子命令
- 用户可不依赖 shell 脚本直接运行核心流程

### T03 设计平台适配接口

目标：

- 集中处理平台差异

建议接口：

- `getDefaultRoots()`
- `getHomeDir()`
- `getShellBackend()`
- `buildShellInvocation(command)`
- `isPortInUse(port)`
- `getClaudeConfigPaths()`
- `getBlockedCommands()`
- `normalizeLocalPath(path)`

验收标准：

- `connect` / `setup` / `start` 不直接判断 `win32`
- 业务层只调用抽象接口

### T04 迁移 start-bridge

现状问题：

- 依赖 `source`
- 依赖 `lsof`
- 依赖 shell 启动方式

涉及当前文件：

- `scripts/start-bridge.sh`
- `local-bridge/src/index.ts`

建议新增：

- `local-cli/src/commands/start.ts`
- `local-cli/src/lib/env.ts`
- `local-cli/src/lib/ports.ts`

具体工作：

- 解析 `.remote-cc.env`
- 计算默认 roots
- 检测端口占用
- 注入 `MCP_*` 环境变量
- 启动 `tsx src/index.ts`

验收标准：

- Linux / macOS 使用体验不回退
- Windows 可直接启动 bridge
- 不再依赖 `lsof`

### T05 迁移 status

现状问题：

- 依赖 `curl`
- 依赖 shell 方式发起 `ssh`

涉及当前文件：

- `scripts/status.sh`

建议新增：

- `local-cli/src/commands/status.ts`
- `local-cli/src/lib/ssh.ts`

具体工作：

- 本地检查 `http://127.0.0.1:<port>/health`
- 远程检查 `ssh` 是否可达
- 获取远端 `claude --version`

验收标准：

- Windows 可查看本地 bridge 和远端状态
- 输出信息与现有脚本等价或更清晰

### T06 迁移 connect

现状问题：

- 依赖 `base64`
- 依赖 `jq`
- 依赖 shell 参数拼接
- 假设本地路径偏 Unix

涉及当前文件：

- `scripts/connect.sh`

建议新增：

- `local-cli/src/commands/connect.ts`
- `local-cli/src/lib/scp.ts`
- `local-cli/src/lib/claude-config.ts`
- `local-cli/src/lib/sse-mcp.ts`

具体工作：

- 读取 `~/.claude.json`
- 提取 SSE MCP 列表
- 构造 SSH 反向隧道参数
- 上传本地 `CLAUDE.md`
- 上传本地 `settings` / `skills` / `commands`
- 启动远端 `prepare-session.sh && claude`
- 用 Node 实现 retry 和回退逻辑

验收标准：

- Linux / macOS 行为不回退
- Windows 能建立 `ssh -R`
- Windows 能同步本地配置
- Windows 能稳定进入云端 Claude 会话

### T07 迁移 setup

现状问题：

- 本地前置检查依赖 shell
- 本地验证 bridge 启动方式偏 Unix

涉及当前文件：

- `setup.sh`

建议新增：

- `local-cli/src/commands/setup.ts`

具体工作：

- 检查 Node / SSH 前置条件
- 本地安装依赖
- 上传云端部署文件
- 执行云端安装与配置
- 在本地启动临时 bridge 做链路验证

验收标准：

- Windows 本地可部署同一套 Ubuntu VPS
- 不依赖 bash 完成本地验证

### T08 `local__bash` 平台抽象

现状问题：

- 当前写死为 `bash -c`

涉及当前文件：

- `local-bridge/src/server.ts`
- `local-bridge/src/config.ts`

建议策略：

- Linux / macOS 默认 `bash`
- Windows MVP 默认 `Git Bash`
- Windows 后续可选 `PowerShell`

具体工作：

- 在配置中新增 `shellBackend`
- 抽离命令调用构造逻辑
- 前台与后台执行都走统一平台适配
- 文案从 “bash command” 改成更中立的 “local shell command”

验收标准：

- Linux / macOS 行为不变
- Windows 上 `local__bash` 可执行基本命令
- `cwd` 在 Windows 路径下生效

### T09 Windows 路径与默认目录适配

现状问题：

- 默认目录依赖 Unix 风格 `HOME`
- Windows 盘符与路径格式未明确验证

涉及当前文件：

- `local-bridge/src/config.ts`
- `local-bridge/src/security.ts`

具体工作：

- 使用 `os.homedir()`
- 补充 Windows 默认 roots 候选
- 复查盘符路径、空格路径、中文路径
- 确认 `assertSafePath` 与 `isPathInside` 在 Windows 下工作正常

验收标准：

- 不手动配置时，Windows 用户也有合理默认 roots
- `C:\Users\name\project` 可正常通过安全检查
- 中文路径可读写

### T10 Windows 危险命令黑名单

现状问题：

- 当前黑名单偏 Unix

涉及当前文件：

- `local-bridge/src/config.ts`
- `local-bridge/test/security.test.ts`

具体工作：

- 增加 Windows 特有危险命令片段
- 按平台组合黑名单
- 补单元测试

建议首批拦截：

- `format `
- `diskpart`
- `del /f /s /q`
- `rmdir /s /q`
- `Remove-Item -Recurse -Force`
- `Stop-Computer`
- `Restart-Computer`
- `shutdown /s`
- `Clear-Disk`

验收标准：

- Windows 常见高风险命令被拦截
- Linux / macOS 黑名单行为不受影响

### T11 云端提示文案平台中立化

现状问题：

- 目前提示文案将本地写死成 “Mac”
- 过度依赖 `cd $LOCAL_DIR && ...` 的 Unix 风格示例

涉及当前文件：

- `cloud-setup/prepare-session.sh`
- `cloud-setup/hooks/block-builtin.sh`

具体工作：

- 改为 `local machine`
- 如有必要，动态提示“可能是 Windows 路径”
- 引导 Claude 优先通过 `cwd` 参数执行命令
- 调整示例命令，避免误导路径格式

验收标准：

- 云端 Claude 在 Windows 会话中更少走错路径
- 文案不再写死本地平台

### T12 Windows MVP 联调

目标：

- 跑通 “Windows 本地 + Ubuntu VPS” 端到端链路

首版建议前置：

- Windows 10/11
- Node.js 20+
- OpenSSH Client
- Git for Windows

联调清单：

- 启动本地 bridge
- 上传本地配置
- 建立 SSH 反向隧道
- 云端 Claude 成功启动
- 云端通过 MCP 读写本地项目

验收标准：

- `read_file` 正常
- `edit_file` 正常
- `write_file` 正常
- `glob` 正常
- `grep` 正常
- `bash` 正常
- 断线重连正常
- 中文路径正常

### T13 补跨平台测试

现状问题：

- 当前测试覆盖较少，偏 Unix 样例

涉及当前文件：

- `local-bridge/test/security.test.ts`

建议新增测试：

- Windows 盘符路径边界
- 空格路径
- 中文路径
- shell backend 选择逻辑
- Windows 黑名单
- CLI 参数覆盖配置逻辑
- SSE MCP 配置解析逻辑

验收标准：

- 关键跨平台逻辑具备单元测试
- Linux 环境下也能验证大部分跨平台代码

### T14 补 Windows 文档

涉及当前文件：

- `README.md`

具体工作：

- 更新前置条件
- 增加 Windows 安装要求
- 增加 Windows 使用示例
- 增加 Git Bash 推荐说明
- 增加 Windows 故障排查

验收标准：

- 新用户可按文档独立完成安装与连接

### T15 PowerShell 模式

目标：

- 提供可选的 Windows PowerShell / pwsh 后端

具体工作：

- 增加 CLI / env 配置项
- 增加 PowerShell 命令构造逻辑
- 增加 PowerShell 风格危险命令检测
- 调整相关文档

验收标准：

- `shellBackend=powershell` 下基本命令可执行
- 与默认后端的切换行为清晰

### T16 Windows 安装分发

目标：

- 降低 Windows 使用门槛

可选方向：

- `npm install -g`
- 可执行入口脚本
- 单文件打包
- Scoop / 安装器支持

验收标准：

- 用户能用更少步骤完成安装

## 9. 建议执行顺序

第一批，先稳住架构：

1. T01
2. T02
3. T03

第二批，完成跨平台主链路：

1. T04
2. T06
3. T08
4. T09
5. T10

第三批，跑通 Windows MVP：

1. T12

第四批，补齐体验与质量：

1. T05
2. T07
3. T11
4. T13
5. T14

第五批，再做增强：

1. T15
2. T16

## 10. 任务优先级建议

### 必须先做

- T01
- T02
- T03
- T04
- T06
- T08
- T09
- T10
- T12

### 可以稍后做

- T05
- T07
- T11
- T13
- T14

### 明确后置

- T15
- T16

## 11. Definition Of Done

一个阶段完成，不以“代码写了”为准，而以“链路真的可用”为准。

### M1 完成标准

- 本地核心逻辑已从 shell 脚本迁移到共享 CLI
- Linux / macOS 不回退
- 平台差异模块边界清晰

### M2 完成标准

- Windows 本地可以启动 bridge
- Windows 本地可以连接 VPS
- 云端 Claude 可以通过 MCP 操作 Windows 本地文件

### M3 完成标准

- README 已补 Windows 文档
- 核心跨平台逻辑有测试覆盖
- 中文路径、空格路径、断线重连已验证

### M4 完成标准

- PowerShell 模式可切换
- Windows 分发方式更简化

## 12. 后续维护规则

后续新增功能时，默认遵守以下规则：

1. 先加到共享核心，不先写进 shell 脚本
2. 如果功能涉及平台差异，只在平台适配层扩展
3. 不允许为了赶进度复制一份 Windows 专用主流程
4. 任何新 CLI 流程都要先考虑 Linux / macOS / Windows 的一致性
5. 文档更新必须与实现同步

## 13. 推荐下一步

建议从以下任务开始：

1. T02：先把 Node CLI 的命令模型和参数规则定下来
2. T03：定义平台适配接口
3. T04：先迁移 `start-bridge`
4. T08：同步准备 `local__bash` 平台抽象

原因：

- 这几个任务能最早把架构从“脚本驱动”转成“共享核心驱动”
- 它们会直接决定后面的 Windows 工作量是线性增长，还是可控增长
