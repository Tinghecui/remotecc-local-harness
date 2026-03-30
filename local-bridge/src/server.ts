import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFile, writeFile, stat, mkdir } from "fs/promises";
import { spawn } from "child_process";
import { dirname, extname } from "path";
import fg from "fast-glob";
import { execFile } from "child_process";
import { promisify } from "util";
import type { BridgeConfig } from "./config.js";
import { assertSafePath, assertSafeCommand, isPathInside, log } from "./security.js";

const execFileAsync = promisify(execFile);

const IMAGE_EXTS = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".svg",
]);

const MIME_MAP: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".bmp": "image/bmp",
  ".ico": "image/x-icon",
};

export function createMcpServer(config: BridgeConfig): McpServer {
  const server = new McpServer({
    name: "remote-cc-local-bridge",
    version: "1.0.0",
  });

  // ==================== read_file ====================
  server.tool(
    "read_file",
    "Read a file from the local filesystem. Returns content with line numbers. Supports images (PNG, JPG, GIF, WebP, etc.) — returns image content directly.",
    {
      file_path: z.string().describe("Absolute path to the file"),
      offset: z.number().optional().describe("Line number to start from (0-based)"),
      limit: z.number().optional().describe("Number of lines to read"),
    },
    async ({ file_path, offset, limit }) => {
      log(config, "read_file", { file_path, offset, limit });
      const safe = assertSafePath(file_path, config);
      const ext = extname(file_path).toLowerCase();

      // Image files: return as MCP image content
      if (IMAGE_EXTS.has(ext)) {
        const buf = await readFile(safe);
        return {
          content: [
            {
              type: "image" as const,
              data: buf.toString("base64"),
              mimeType: MIME_MAP[ext] || "application/octet-stream",
            },
          ],
        };
      }

      // PDF files: extract text via pdftotext if available, otherwise return info
      if (ext === ".pdf") {
        try {
          const { stdout } = await execFileAsync("pdftotext", [safe, "-"], {
            timeout: 30000,
            maxBuffer: 2 * 1024 * 1024,
          });
          return { content: [{ type: "text" as const, text: stdout }] };
        } catch {
          return {
            content: [
              {
                type: "text" as const,
                text: `PDF file: ${file_path}\npdftotext not available. Install poppler to extract text: brew install poppler`,
              },
            ],
          };
        }
      }

      // Text files: existing behavior
      const content = await readFile(safe, "utf-8");
      const lines = content.split("\n");
      const start = offset ?? 0;
      const end = limit ? start + limit : lines.length;
      const sliced = lines.slice(start, end);
      const numbered = sliced
        .map((line, i) => `${start + i + 1}\t${line}`)
        .join("\n");
      return { content: [{ type: "text" as const, text: numbered }] };
    }
  );

  // ==================== edit_file ====================
  server.tool(
    "edit_file",
    "Edit a file by replacing a string. The old_string must be unique in the file.",
    {
      file_path: z.string().describe("Absolute path to the file"),
      old_string: z.string().describe("The exact string to find and replace"),
      new_string: z.string().describe("The replacement string"),
      replace_all: z
        .boolean()
        .optional()
        .describe("Replace all occurrences (default: false)"),
    },
    async ({ file_path, old_string, new_string, replace_all }) => {
      log(config, "edit_file", { file_path, old_string: old_string.slice(0, 50) });
      const safe = assertSafePath(file_path, config);
      let content = await readFile(safe, "utf-8");

      if (!content.includes(old_string)) {
        throw new Error(
          "old_string not found in file. Make sure it matches exactly including whitespace."
        );
      }

      let editStart: number;

      if (replace_all) {
        editStart = content.indexOf(old_string);
        content = content.replaceAll(old_string, new_string);
      } else {
        // 确保 old_string 是唯一的
        const firstIdx = content.indexOf(old_string);
        const secondIdx = content.indexOf(old_string, firstIdx + 1);
        if (secondIdx !== -1) {
          throw new Error(
            "old_string is not unique in the file. Provide more context or use replace_all."
          );
        }
        editStart = firstIdx;
        content =
          content.slice(0, firstIdx) +
          new_string +
          content.slice(firstIdx + old_string.length);
      }

      await writeFile(safe, content);

      // Return snippet around the edit for confirmation
      const lines = content.split("\n");
      const editLine = content.slice(0, editStart).split("\n").length - 1;
      const snippetStart = Math.max(0, editLine - 3);
      const snippetEnd = Math.min(lines.length, editLine + new_string.split("\n").length + 3);
      const snippet = lines
        .slice(snippetStart, snippetEnd)
        .map((line, i) => `${snippetStart + i + 1}\t${line}`)
        .join("\n");

      return {
        content: [
          {
            type: "text" as const,
            text: `OK: edited ${file_path}\n\n${snippet}`,
          },
        ],
      };
    }
  );

  // ==================== write_file ====================
  server.tool(
    "write_file",
    "Create or overwrite a file with the given content.",
    {
      file_path: z.string().describe("Absolute path to the file"),
      content: z.string().describe("The content to write"),
    },
    async ({ file_path, content: fileContent }) => {
      log(config, "write_file", { file_path });
      const safe = assertSafePath(file_path, config);
      await mkdir(dirname(safe), { recursive: true });
      await writeFile(safe, fileContent);
      return { content: [{ type: "text" as const, text: `OK: wrote ${file_path}` }] };
    }
  );

  // ==================== bash ====================
  server.tool(
    "bash",
    "Execute a bash command on the local machine. Starts in the provided working directory and uses the local user's normal permissions.",
    {
      command: z.string().describe("The bash command to execute"),
      cwd: z
        .string()
        .optional()
        .describe("Working directory (must be within allowed roots)"),
      timeout: z
        .number()
        .optional()
        .describe("Timeout in milliseconds (default: 120000)"),
      description: z
        .string()
        .optional()
        .describe("Human-readable description of what this command does"),
      run_in_background: z
        .boolean()
        .optional()
        .describe("Run command in background and return PID immediately"),
    },
    async ({ command, cwd, timeout, description, run_in_background }) => {
      log(config, "bash", { command, cwd, description });
      assertSafeCommand(command, config);

      const workdir = cwd ? assertSafePath(cwd, config) : config.allowedRoots[0];

      // Background mode: spawn detached and return PID
      if (run_in_background) {
        const proc = spawn("bash", ["-c", command], {
          cwd: workdir,
          detached: true,
          stdio: "ignore",
        });
        proc.unref();
        return {
          content: [
            {
              type: "text" as const,
              text: `Background PID: ${proc.pid}`,
            },
          ],
        };
      }

      const timeoutMs = timeout ?? config.commandTimeout;

      return new Promise((resolve) => {
        const proc = spawn("bash", ["-c", command], {
          cwd: workdir,
          timeout: timeoutMs,
          env: { ...process.env },
        });

        let stdout = "";
        let stderr = "";

        proc.stdout.on("data", (d: Buffer) => {
          stdout += d.toString();
          // 限制输出大小，防止 OOM
          if (stdout.length > 1024 * 1024) {
            proc.kill();
            stdout = stdout.slice(0, 1024 * 1024) + "\n... [output truncated at 1MB]";
          }
        });

        proc.stderr.on("data", (d: Buffer) => {
          stderr += d.toString();
          if (stderr.length > 512 * 1024) {
            stderr = stderr.slice(0, 512 * 1024) + "\n... [stderr truncated at 512KB]";
          }
        });

        proc.on("close", (code) => {
          resolve({
            content: [
              {
                type: "text" as const,
                text: JSON.stringify(
                  { stdout, stderr, exitCode: code ?? 1 },
                  null,
                  2
                ),
              },
            ],
          });
        });

        proc.on("error", (err) => {
          resolve({
            content: [
              {
                type: "text" as const,
                text: JSON.stringify(
                  { stdout, stderr: err.message, exitCode: 1 },
                  null,
                  2
                ),
              },
            ],
          });
        });
      });
    }
  );

  // ==================== glob ====================
  server.tool(
    "glob",
    "Fast file pattern matching tool. Supports glob patterns like '**/*.js'. Returns matching file paths sorted by modification time (newest first).",
    {
      pattern: z.string().describe("Glob pattern (e.g. '**/*.ts', 'src/**/*.js')"),
      path: z
        .string()
        .optional()
        .describe("Base directory to search in (default: first allowed root)"),
      head_limit: z
        .number()
        .optional()
        .describe("Limit number of results returned (default: 250)"),
    },
    async ({ pattern, path, head_limit }) => {
      log(config, "glob", { pattern, path });
      const base = path ? assertSafePath(path, config) : config.allowedRoots[0];
      const limit = head_limit ?? 250;

      const files = await fg(pattern, {
        cwd: base,
        absolute: true,
        onlyFiles: true,
        followSymbolicLinks: false,
        ignore: ["**/node_modules/**", "**/.git/**"],
        stats: true,
      });

      // 验证所有结果都在允许范围内
      const safeFiles = files.filter((f) =>
        config.allowedRoots.some((root) => isPathInside(root, typeof f === "string" ? f : f.path))
      );

      // Sort by modification time (newest first)
      const withStats = await Promise.all(
        safeFiles.map(async (f) => {
          const filePath = typeof f === "string" ? f : f.path;
          try {
            const s = await stat(filePath);
            return { path: filePath, mtime: s.mtimeMs };
          } catch {
            return { path: filePath, mtime: 0 };
          }
        })
      );
      withStats.sort((a, b) => b.mtime - a.mtime);

      const limited = withStats.slice(0, limit).map((f) => f.path);

      return {
        content: [
          {
            type: "text" as const,
            text: limited.length > 0 ? limited.join("\n") : "No files found",
          },
        ],
      };
    }
  );

  // ==================== grep ====================
  server.tool(
    "grep",
    "Search file contents using ripgrep. Supports regex, output modes (content/files_with_matches/count), context lines, and file type filtering.",
    {
      pattern: z.string().describe("Regex pattern to search for"),
      path: z
        .string()
        .optional()
        .describe("Directory or file to search in"),
      glob: z
        .string()
        .optional()
        .describe("File glob filter (e.g. '*.ts', '*.{js,jsx}')"),
      ignore_case: z.boolean().optional().describe("Case insensitive search"),
      output_mode: z
        .enum(["content", "files_with_matches", "count"])
        .optional()
        .describe("Output mode (default: files_with_matches)"),
      context: z.number().optional().describe("Lines of context around each match (-C)"),
      before_context: z.number().optional().describe("Lines before each match (-B)"),
      after_context: z.number().optional().describe("Lines after each match (-A)"),
      head_limit: z
        .number()
        .optional()
        .describe("Limit output entries (default: 250)"),
      type: z
        .string()
        .optional()
        .describe("File type filter (e.g. 'js', 'py', 'ts')"),
      multiline: z
        .boolean()
        .optional()
        .describe("Enable multiline matching where . matches newlines"),
    },
    async ({
      pattern,
      path,
      glob: fileGlob,
      ignore_case,
      output_mode,
      context,
      before_context,
      after_context,
      head_limit,
      type: fileType,
      multiline,
    }) => {
      log(config, "grep", { pattern, path, glob: fileGlob, output_mode });
      const base = path ? assertSafePath(path, config) : config.allowedRoots[0];
      const mode = output_mode ?? "files_with_matches";
      const limit = head_limit ?? 250;

      const args = ["--color=never", "--no-heading"];

      // Output mode
      if (mode === "files_with_matches") {
        args.push("-l");
      } else if (mode === "count") {
        args.push("-c");
      } else {
        // content mode
        args.push("-n");
      }

      if (ignore_case) args.push("-i");
      if (fileGlob) args.push("--glob", fileGlob);
      if (fileType) args.push("--type", fileType);
      if (multiline) args.push("-U", "--multiline-dotall");

      // Context (only meaningful for content mode)
      if (mode === "content") {
        if (context != null) args.push("-C", String(context));
        if (before_context != null) args.push("-B", String(before_context));
        if (after_context != null) args.push("-A", String(after_context));
      }

      args.push("--", pattern, base);

      try {
        const { stdout } = await execFileAsync("rg", args, {
          timeout: 30000,
          maxBuffer: 2 * 1024 * 1024,
        });

        // Apply head_limit
        const lines = stdout.split("\n").filter((l) => l !== "");
        const limited =
          lines.length > limit
            ? lines.slice(0, limit).join("\n") + `\n... [${lines.length - limit} more entries]`
            : lines.join("\n");
        return { content: [{ type: "text" as const, text: limited || "No matches found" }] };
      } catch (e: unknown) {
        const err = e as { stdout?: string; code?: number };
        if (err.code === 1) {
          return { content: [{ type: "text" as const, text: "No matches found" }] };
        }
        return {
          content: [{ type: "text" as const, text: err.stdout || "grep error" }],
        };
      }
    }
  );

  return server;
}
