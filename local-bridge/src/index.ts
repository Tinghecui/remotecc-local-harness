import express from "express";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { readdir, readFile, writeFile, stat, mkdir, utimes } from "fs/promises";
import { join } from "path";
import { homedir } from "os";
import { loadConfig } from "./config.js";
import { createMcpServer } from "./server.js";
import { isPathInside, resolvePath } from "./security.js";

const config = loadConfig();

const app = express();
app.use(express.json());

// OAuth 探测 - 告诉客户端不需要认证
app.get("/.well-known/oauth-authorization-server", (_req, res) => {
  res.status(404).end();
});
app.get("/.well-known/oauth-protected-resource", (_req, res) => {
  res.status(404).end();
});
app.post("/register", (_req, res) => {
  res.status(404).end();
});

// 健康检查
app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    host: config.host,
    allowedRoots: config.allowedRoots,
    uptime: process.uptime(),
  });
});

// ============================================================
// Memory 同步 REST 端点（非 MCP 工具）
// ============================================================

const CLAUDE_DIR = join(homedir(), ".claude");

function isUnderClaudeDir(p: string): boolean {
  return isPathInside(CLAUDE_DIR, p);
}

// GET /sync/memory — 返回内存文件列表+内容+mtime
app.get("/sync/memory", async (req, res) => {
  const memoryPath = req.query.path as string;
  if (!memoryPath || !isUnderClaudeDir(memoryPath)) {
    res.status(403).json({ error: "path must be under ~/.claude/" });
    return;
  }

  try {
    const resolved = resolvePath(memoryPath);
    try {
      await stat(resolved);
    } catch {
      res.json({ files: [] });
      return;
    }

    const entries = await readdir(resolved);
    const files: Array<{ name: string; content: string; mtime: number }> = [];

    for (const entry of entries) {
      const filePath = join(resolved, entry);
      const fileStat = await stat(filePath);
      if (fileStat.isFile()) {
        const content = await readFile(filePath, "utf-8");
        files.push({ name: entry, content, mtime: fileStat.mtimeMs });
      }
    }

    res.json({ files });
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

// POST /sync/memory — 写入内存文件
app.post("/sync/memory", async (req, res) => {
  const memoryPath = req.query.path as string;
  if (!memoryPath || !isUnderClaudeDir(memoryPath)) {
    res.status(403).json({ error: "path must be under ~/.claude/" });
    return;
  }

  try {
    const resolved = resolvePath(memoryPath);
    await mkdir(resolved, { recursive: true });

    const { files } = req.body as {
      files: Array<{ name: string; content: string; mtime: number }>;
    };

    if (!Array.isArray(files)) {
      res.status(400).json({ error: "body must contain files array" });
      return;
    }

    let written = 0;
    for (const file of files) {
      const filePath = join(resolved, file.name);
      if (!isPathInside(resolved, filePath)) continue; // 防目录遍历
      await writeFile(filePath, file.content);
      if (file.mtime) {
        const mtime = new Date(file.mtime);
        await utimes(filePath, mtime, mtime);
      }
      written++;
    }

    res.json({ ok: true, written });
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

// GET /sync/memory-path — 根据工作目录查找本地 Claude 内存路径
app.get("/sync/memory-path", async (req, res) => {
  const workdir = req.query.workdir as string;
  if (!workdir) {
    res.status(400).json({ error: "workdir parameter required" });
    return;
  }

  const projectsDir = join(CLAUDE_DIR, "projects");
  try {
    const entries = await readdir(projectsDir);
    // Claude 把绝对路径的 / 替换为 -，开头可能有也可能没有 -
    const normalized = workdir.replace(/\//g, "-").replace(/^-/, "");
    const match = entries.find(
      (e) =>
        e === normalized ||
        e === `-${normalized}` ||
        e.replace(/^-/, "") === normalized
    );
    if (match) {
      res.json({ memoryPath: join(projectsDir, match, "memory") });
    } else {
      res.status(404).json({ error: "no matching project directory found", searched: normalized });
    }
  } catch {
    res.status(500).json({ error: "cannot read projects directory" });
  }
});

// SSE transport 管理
const transports = new Map<string, SSEServerTransport>();

// SSE 连接端点
app.get("/sse", async (req, res) => {
  console.log(`[${new Date().toISOString()}] New SSE connection from ${req.ip}`);

  const transport = new SSEServerTransport("/messages", res);
  const sessionId = transport.sessionId;
  transports.set(sessionId, transport);

  const server = createMcpServer(config);

  transport.onclose = () => {
    console.log(`[${new Date().toISOString()}] SSE session ${sessionId} closed`);
    transports.delete(sessionId);
  };

  await server.connect(transport);
});

// 消息端点
app.post("/messages", async (req, res) => {
  const sessionId = req.query.sessionId as string;
  const transport = transports.get(sessionId);

  if (!transport) {
    res.status(400).json({ error: "no session found", sessionId });
    return;
  }

  await transport.handlePostMessage(req, res, req.body);
});

app.listen(config.port, config.host, () => {
  const listenAddress = `${config.host}:${config.port}`;
  console.log(`
╔══════════════════════════════════════════════════╗
║  Remote CC - Local MCP Bridge (SSE)              ║
╠══════════════════════════════════════════════════╣
║  Listen:  ${listenAddress.padEnd(38)}║
║  Roots:                                          ║
${config.allowedRoots.map((r) => `║    ${r.padEnd(44)}║`).join("\n")}
╠══════════════════════════════════════════════════╣
║  SSE endpoint:  /sse                             ║
║  Msg endpoint:  /messages                        ║
║  Security: loopback only + SSH tunnel            ║
║  Waiting for connections...                      ║
╚══════════════════════════════════════════════════╝
`);
});
