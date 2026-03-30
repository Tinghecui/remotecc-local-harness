import { isAbsolute, relative, resolve } from "path";
import type { BridgeConfig } from "./config.js";

export function resolvePath(filePath: string): string {
  return resolve(filePath);
}

export function isPathInside(rootPath: string, candidatePath: string): boolean {
  const root = resolvePath(rootPath);
  const candidate = resolvePath(candidatePath);
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

export function assertSafePath(filePath: string, config: BridgeConfig): string {
  if (!isAbsolute(filePath)) {
    throw new Error(`Path must be absolute: ${filePath}`);
  }

  const resolved = resolvePath(filePath);
  const isAllowed = config.allowedRoots.some((root) => isPathInside(root, resolved));

  if (!isAllowed) {
    throw new Error(
      `Path outside allowed roots: ${resolved}\nAllowed: ${config.allowedRoots.join(", ")}`
    );
  }

  return resolved;
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
