import { resolve } from "path";
import { existsSync } from "fs";

export interface BridgeConfig {
  host: string;
  port: number;
  allowedRoots: string[];
  blockedCommands: string[];
  commandTimeout: number;
  logRequests: boolean;
}

export function loadConfig(): BridgeConfig {
  const allowedRootsEnv = process.env.MCP_ALLOWED_ROOTS;
  const homeDir = resolve(process.env.HOME || "/");
  const defaultRoots = [resolve(homeDir, "Desktop"), resolve(homeDir, "projects"), resolve(homeDir, "Documents")]
    .filter((root, index, roots) => existsSync(root) && roots.indexOf(root) === index);
  const allowedRoots = (allowedRootsEnv
    ? allowedRootsEnv.split(",").map((r) => resolve(r.trim())).filter(Boolean)
    : defaultRoots
  ).filter((root, index, roots) => roots.indexOf(root) === index);
  const finalAllowedRoots = allowedRoots.length > 0 ? allowedRoots : [homeDir];

  // 验证目录存在
  for (const root of finalAllowedRoots) {
    if (!existsSync(root)) {
      console.warn(`Warning: allowed root does not exist: ${root}`);
    }
  }

  return {
    host: process.env.MCP_HOST?.trim() || "127.0.0.1",
    port: Number.parseInt(process.env.MCP_PORT || "3100", 10),
    allowedRoots: finalAllowedRoots,
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
    commandTimeout: Number.parseInt(process.env.MCP_CMD_TIMEOUT || "120000", 10),
    logRequests: process.env.MCP_LOG !== "false",
  };
}
