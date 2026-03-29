import { resolve, normalize } from "path";
import type { BridgeConfig } from "./config.js";

export function assertSafePath(filePath: string, config: BridgeConfig): string {
  const resolved = resolve(filePath);
  const normalized = normalize(resolved);

  // 防止路径穿越
  if (normalized !== resolved) {
    throw new Error(`Path traversal detected: ${filePath}`);
  }

  const isAllowed = config.allowedRoots.some((root) =>
    normalized.startsWith(root + "/") || normalized === root
  );

  if (!isAllowed) {
    throw new Error(
      `Path outside allowed roots: ${normalized}\nAllowed: ${config.allowedRoots.join(", ")}`
    );
  }

  return normalized;
}

export function assertSafeCommand(command: string, config: BridgeConfig): void {
  const normalized = command.trim().toLowerCase();

  for (const blocked of config.blockedCommands) {
    if (normalized.includes(blocked.toLowerCase())) {
      throw new Error(`Blocked command detected: ${blocked}`);
    }
  }
}

export function log(config: BridgeConfig, tool: string, params: Record<string, unknown>): void {
  if (!config.logRequests) return;
  const time = new Date().toISOString();
  const summary = Object.entries(params)
    .map(([k, v]) => {
      const s = String(v);
      return `${k}=${s.length > 80 ? s.slice(0, 80) + "..." : s}`;
    })
    .join(" ");
  console.log(`[${time}] ${tool} | ${summary}`);
}
