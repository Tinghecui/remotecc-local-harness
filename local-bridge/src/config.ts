import { resolve } from "path";
import { existsSync } from "fs";

export interface BridgeConfig {
  port: number;
  allowedRoots: string[];
  blockedCommands: string[];
  commandTimeout: number;
  logRequests: boolean;
}

export function loadConfig(): BridgeConfig {
  const allowedRootsEnv = process.env.MCP_ALLOWED_ROOTS;
  const allowedRoots = allowedRootsEnv
    ? allowedRootsEnv.split(",").map((r) => resolve(r.trim()))
    : [resolve(process.env.HOME || "/", "projects")];

  // 验证目录存在
  for (const root of allowedRoots) {
    if (!existsSync(root)) {
      console.warn(`Warning: allowed root does not exist: ${root}`);
    }
  }

  return {
    port: parseInt(process.env.MCP_PORT || "3100"),
    allowedRoots,
    blockedCommands: [
      "rm -rf /",
      "rm -rf /*",
      "mkfs",
      "dd if=/dev/zero",
      "dd if=/dev/random",
      ":(){ :|:& };:",
      "> /dev/sda",
      "chmod -R 777 /",
      "shutdown",
      "reboot",
      "halt",
      "init 0",
      "init 6",
    ],
    commandTimeout: parseInt(process.env.MCP_CMD_TIMEOUT || "120000"),
    logRequests: process.env.MCP_LOG !== "false",
  };
}
