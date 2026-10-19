import { spawnSync } from "node:child_process"
import { mkdtempSync, rmSync, symlinkSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, sep } from "node:path"
import { fileURLToPath } from "node:url"

const root = fileURLToPath(new URL("../", import.meta.url))
function run(command, args, cwd = root, capture = false) {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    encoding: "utf8",
    stdio: capture ? "pipe" : "inherit",
  })
  if (result.error || result.status !== 0) throw new Error("A pre-commit check failed")
  return result.stdout
}

// Check index contents without stashing work, refreshing the index or writing the source tree.
const snapshot = mkdtempSync(join(tmpdir(), "pi-remote-index-"))
try {
  const names = run(
    "git",
    ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
    root,
    true,
  )
    .split("\0")
    .filter(Boolean)
  run("git", ["checkout-index", "--all", `--prefix=${snapshot}${sep}`])
  symlinkSync(join(root, "node_modules"), join(snapshot, "node_modules"), "dir")
  run(
    process.execPath,
    [
      join(root, "node_modules/@biomejs/biome/bin/biome"),
      "check",
      "--vcs-enabled=false",
      "--no-errors-on-unmatched",
      ...names.map((name) => `.${sep}${name}`),
    ],
    snapshot,
  )
  const compiler = join(root, "node_modules/typescript/bin/tsc")
  run(process.execPath, [compiler, "--noEmit"], snapshot)
  run(process.execPath, [compiler, "--noEmit"], root)
} catch {
  process.exitCode = 1
} finally {
  rmSync(snapshot, { recursive: true, force: true })
}
