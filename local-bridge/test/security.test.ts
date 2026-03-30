import assert from "node:assert/strict";
import test from "node:test";
import type { BridgeConfig } from "../src/config.js";
import { assertSafeCommand, assertSafePath, isPathInside } from "../src/security.js";

const config: BridgeConfig = {
  host: "127.0.0.1",
  port: 3100,
  allowedRoots: ["/tmp/remote-cc-root", "/Users/test/.claude"],
  blockedCommands: ["rm -rf /", "shutdown"],
  commandTimeout: 120000,
  logRequests: false,
};

test("isPathInside enforces real directory boundaries", () => {
  assert.equal(isPathInside("/tmp/remote-cc-root", "/tmp/remote-cc-root/file.txt"), true);
  assert.equal(isPathInside("/tmp/remote-cc-root", "/tmp/remote-cc-root/nested/file.txt"), true);
  assert.equal(isPathInside("/tmp/remote-cc-root", "/tmp/remote-cc-root-evil/file.txt"), false);
  assert.equal(isPathInside("/Users/test/.claude", "/Users/test/.claudeevil/file.txt"), false);
});

test("assertSafePath requires absolute paths inside allowed roots", () => {
  assert.throws(() => assertSafePath("relative.txt", config), /Path must be absolute/);
  assert.throws(
    () => assertSafePath("/tmp/remote-cc-root-evil/file.txt", config),
    /Path outside allowed roots/
  );
  assert.equal(
    assertSafePath("/tmp/remote-cc-root/project/README.md", config),
    "/tmp/remote-cc-root/project/README.md"
  );
});

test("assertSafeCommand still blocks configured dangerous snippets", () => {
  assert.throws(() => assertSafeCommand("echo hi && rm -rf /", config), /Blocked command/);
  assert.doesNotThrow(() => assertSafeCommand("printf 'safe'\n", config));
});
