// Run with an installed Pi CLI on PATH. No Pi runtime is imported by the
// client module itself. This test uses the installed loader and TypeBox.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { test } from "node:test";

const piCLI = await realpath(execFileSync("which", ["pi"], { encoding: "utf8" }).trim());
const packageRoot = resolve(dirname(piCLI), "../..");
const requirePi = createRequire(join(packageRoot, "package.json"));
const { DefaultResourceLoader } = await import(pathToFileURL(join(packageRoot, "dist/core/resource-loader.js")).href);
const { SettingsManager } = await import(pathToFileURL(join(packageRoot, "dist/core/settings-manager.js")).href);
const { Check } = await import(pathToFileURL(requirePi.resolve("typebox/value")).href);
const cwd = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const extensionPath = join(cwd, ".pi/extensions/pi-remote-debug.ts");

test("installed Pi discovers the project extension only after trust, with valid strict tool schemas", async () => {
  const agentDir = await mkdtemp(join(homedir(), ".pi-remote-debug-load-test-"));
  try {
    const settingsManager = SettingsManager.inMemory();
    const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager, disabledBuiltinExtensions: ["mcp", "codemode", "tool-search", "llama.cpp"], noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true });
    await loader.reload({ resolveProjectTrust: async () => false });
    assert.equal(loader.getExtensions().extensions.some((e: any) => e.path === extensionPath), false);
    await loader.reload({ resolveProjectTrust: async () => true });
    const loaded = loader.getExtensions(); assert.deepEqual(loaded.errors, []);
    const extension = loaded.extensions.find((e: any) => e.path === extensionPath); assert.ok(extension);
    assert.deepEqual([...extension.tools.keys()], ["pi_remote_debug_status", "pi_remote_debug_capture", "pi_remote_debug_interact"]);
    assert.deepEqual([...extension.handlers.keys()].sort(), ["session_shutdown", "session_start"]);
    for (const { definition } of extension.tools.values()) {
      const interaction = definition.name === "pi_remote_debug_interact";
      assert.equal(Check(definition.parameters, {}), !interaction);
      if (interaction) {
        assert.equal(Check(definition.parameters, { action: "navigate", value: "overview" }), true);
        assert.equal(Check(definition.parameters, { action: "click", value: "mac-files" }), true);
        assert.match(definition.description, /native accessibility press/);
        for (const invalid of [{ action: "submit", value: "text" }, { action: "type_text", value: "" }, { action: "type_text", value: "x".repeat(2049) }, { action: "sidebar", value: "show", token: "secret" }]) assert.equal(Check(definition.parameters, invalid), false);
        assert.equal(Check(definition.outputSchema, { action: "type_text", outcome: "applied" }), true);
        assert.equal(Check(definition.outputSchema, { action: "click", outcome: "applied" }), true);
        for (const invalid of [{ action: "submit", outcome: "applied" }, { action: "type_text", outcome: "failed" }, { action: "type_text", outcome: "applied", value: "secret" }, { action: "click", outcome: "failed" }, { action: "click", outcome: "applied", target: "mac-files" }]) assert.equal(Check(definition.outputSchema, invalid), false);
        assert.deepEqual(definition.annotations, { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false });
      }
      for (const invalid of [{ path: "/tmp" }, { token: "secret" }, null, []]) assert.equal(Check(definition.parameters, invalid), false);
    }
    // The loaded factory does not connect or read endpoint.json. Shutdown is
    // idempotent and makes old tools fail before discovery, including on reload.
    for (const shutdown of extension.handlers.get("session_shutdown")) await shutdown({ type: "session_shutdown", reason: "reload" }, {});
    for (const { definition } of extension.tools.values()) {
      const warning = definition.name === "pi_remote_debug_interact" ? " The interaction may already apply. Inspect the app before retrying. No automatic retry was made." : "";
      await assert.rejects(definition.execute("test", {}, undefined, undefined, { mode: "rpc" }), { message: "Pi Remote debug request was cancelled." + warning });
    }
  } finally { await rm(agentDir, { recursive: true, force: true }); }
});
