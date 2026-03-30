/**
 * Stdio-to-SSE MCP Proxy
 *
 * Wraps a stdio MCP server as an SSE endpoint so it can be tunneled
 * through SSH and used by remote Claude Code.
 *
 * Usage: npx tsx src/stdio-proxy.ts <port> <command> [args...]
 * Example: npx tsx src/stdio-proxy.ts 8808 npx chrome-devtools-mcp@latest
 */

import express from "express";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js";

const port = parseInt(process.argv[2]);
const command = process.argv[3];
const args = process.argv.slice(4);

if (!port || !command) {
  console.error("Usage: stdio-proxy <port> <command> [args...]");
  console.error("Example: stdio-proxy 8808 npx chrome-devtools-mcp@latest");
  process.exit(1);
}

const app = express();
app.use(express.json());

// OAuth probe - no auth needed
app.get("/.well-known/oauth-authorization-server", (_req, res) => res.status(404).json({}));
app.get("/.well-known/oauth-protected-resource", (_req, res) => res.status(404).json({}));
app.post("/register", (_req, res) => res.status(404).json({}));

app.get("/health", (_req, res) => res.json({ status: "ok", command, args }));

interface Session {
  sse: SSEServerTransport;
  stdio: StdioClientTransport;
}

const sessions = new Map<string, Session>();

app.get("/sse", async (req, res) => {
  console.log(`[${new Date().toISOString()}] New SSE connection from ${req.ip}`);

  const sseTransport = new SSEServerTransport("/messages", res);
  const sessionId = (sseTransport as { sessionId: string }).sessionId;

  // Spawn a new stdio process for this connection
  const stdioTransport = new StdioClientTransport({ command, args });

  sessions.set(sessionId, { sse: sseTransport, stdio: stdioTransport });

  // Wire: SSE client → stdio server
  sseTransport.onmessage = (msg: JSONRPCMessage) => {
    stdioTransport.send(msg).catch((err) => {
      console.error(`[${sessionId}] SSE→stdio send error:`, err.message);
    });
  };

  // Wire: stdio server → SSE client
  stdioTransport.onmessage = (msg: JSONRPCMessage) => {
    sseTransport.send(msg).catch((err) => {
      console.error(`[${sessionId}] stdio→SSE send error:`, err.message);
    });
  };

  // Cleanup on close
  const cleanup = () => {
    console.log(`[${new Date().toISOString()}] Session ${sessionId} closed`);
    sessions.delete(sessionId);
    stdioTransport.close().catch(() => {});
    sseTransport.close().catch(() => {});
  };

  sseTransport.onclose = cleanup;
  stdioTransport.onclose = cleanup;

  sseTransport.onerror = (err) => {
    console.error(`[${sessionId}] SSE error:`, err.message);
  };
  stdioTransport.onerror = (err) => {
    console.error(`[${sessionId}] stdio error:`, err.message);
  };

  // Start both transports
  try {
    await sseTransport.start();
    await stdioTransport.start();
    console.log(`[${new Date().toISOString()}] Session ${sessionId} established`);
  } catch (err) {
    console.error(`[${sessionId}] Failed to start:`, err);
    sessions.delete(sessionId);
    res.end();
  }
});

app.post("/messages", async (req, res) => {
  const sessionId = req.query.sessionId as string;
  const session = sessions.get(sessionId);

  if (!session) {
    res.status(400).json({ error: "no session found", sessionId });
    return;
  }

  await session.sse.handlePostMessage(req, res, req.body);
});

app.listen(port, "127.0.0.1", () => {
  console.log(`
╔══════════════════════════════════════════════════╗
║  Stdio→SSE MCP Proxy                            ║
╠══════════════════════════════════════════════════╣
║  Port:     ${String(port).padEnd(37)}║
║  Command:  ${(command + " " + args.join(" ")).slice(0, 37).padEnd(37)}║
║  SSE:      /sse                                  ║
║  Waiting for connections...                      ║
╚══════════════════════════════════════════════════╝
`);
});
