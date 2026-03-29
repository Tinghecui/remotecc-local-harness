import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFile, writeFile, stat, mkdir } from "fs/promises";
import { spawn } from "child_process";
import { dirname } from "path";
import fg from "fast-glob";
import { execFile } from "child_process";
import { promisify } from "util";
import type { BridgeConfig } from "./config.js";
import { assertSafePath, assertSafeCommand, log } from "./security.js";

const execFileAsync = promisify(execFile);

export function createMcpServer(config: BridgeConfig): McpServer {
  const server = new McpServer({
    name: "remote-cc-local-bridge",
    version: "1.0.0",
  });

  // ==================== read_file ====================
  server.tool(
    "read_file",
    "Read a file from the local filesystem. Returns content with line numbers.",
    {
      file_path: z.string().describe("Absolute path to the file"),
      offset: z.number().optional().describe("Line number to start from (0-based)"),
      limit: z.number().optional().describe("Number of lines to read"),
    },
    async ({ file_path, offset, limit }) => {
      log(config, "read_file", { file_path, offset, limit });
      const safe = assertSafePath(file_path, config);
      const content = await readFile(safe, "utf-8");
      const lines = content.split("\n");
      const start = offset ?? 0;
      const end = limit ? start + limit : lines.length;
      const sliced = lines.slice(start, end);
      const numbered = sliced
        .map((line, i) => `${start + i + 1}\t${line}`)
        .join("\n");
      return { content: [{ type: "text", text: numbered }] };
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

      if (replace_all) {
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
        content =
          content.slice(0, firstIdx) +
          new_string +
          content.slice(firstIdx + old_string.length);
      }

      await writeFile(safe, content);
      return { content: [{ type: "text", text: `OK: edited ${file_path}` }] };
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
      return { content: [{ type: "text", text: `OK: wrote ${file_path}` }] };
    }
  );

  // ==================== bash ====================
  server.tool(
    "bash",
    "Execute a bash command on the local machine. Returns stdout, stderr, and exit code.",
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
    },
    async ({ command, cwd, timeout }) => {
      log(config, "bash", { command, cwd });
      assertSafeCommand(command, config);

      const workdir = cwd ? assertSafePath(cwd, config) : config.allowedRoots[0];
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
                type: "text",
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
                type: "text",
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
    "Find files matching a glob pattern in a directory.",
    {
      pattern: z.string().describe("Glob pattern (e.g. '**/*.ts', 'src/**/*.js')"),
      path: z
        .string()
        .optional()
        .describe("Base directory to search in (default: first allowed root)"),
    },
    async ({ pattern, path }) => {
      log(config, "glob", { pattern, path });
      const base = path ? assertSafePath(path, config) : config.allowedRoots[0];
      const files = await fg(pattern, {
        cwd: base,
        absolute: true,
        onlyFiles: true,
        followSymbolicLinks: false,
        ignore: ["**/node_modules/**", "**/.git/**"],
      });

      // 验证所有结果都在允许范围内
      const safeFiles = files.filter((f) =>
        config.allowedRoots.some((root) => f.startsWith(root))
      );

      return {
        content: [
          {
            type: "text",
            text: safeFiles.length > 0 ? safeFiles.join("\n") : "No files found",
          },
        ],
      };
    }
  );

  // ==================== grep ====================
  server.tool(
    "grep",
    "Search file contents using ripgrep. Returns matching lines with file paths and line numbers.",
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
    },
    async ({ pattern, path, glob: fileGlob, ignore_case }) => {
      log(config, "grep", { pattern, path, glob: fileGlob });
      const base = path ? assertSafePath(path, config) : config.allowedRoots[0];

      const args = ["--color=never", "-n", "--no-heading"];
      if (ignore_case) args.push("-i");
      if (fileGlob) args.push("--glob", fileGlob);
      args.push("--", pattern, base);

      try {
        const { stdout } = await execFileAsync("rg", args, {
          timeout: 30000,
          maxBuffer: 1024 * 1024,
        });
        // 限制输出行数
        const lines = stdout.split("\n");
        const limited =
          lines.length > 500
            ? lines.slice(0, 500).join("\n") + `\n... [${lines.length - 500} more lines]`
            : stdout;
        return { content: [{ type: "text", text: limited }] };
      } catch (e: unknown) {
        const err = e as { stdout?: string; code?: number };
        if (err.code === 1) {
          // rg exit code 1 = no matches
          return { content: [{ type: "text", text: "No matches found" }] };
        }
        return {
          content: [{ type: "text", text: err.stdout || "grep error" }],
        };
      }
    }
  );

  return server;
}
