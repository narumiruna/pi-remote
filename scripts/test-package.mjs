import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

// Build, pack and install only in temporary directories. Do not change the
// repository's dist, node_modules, lockfile, worktree or Git index.
const project = fileURLToPath(new URL("../", import.meta.url))
const scratch = mkdtempSync(join(tmpdir(), "pi-package-test-"))
function run(cwd, command, args) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    timeout: 120_000,
    env: { ...process.env, HUSKY: "0" },
  })
  if (result.error) throw result.error
  assert.equal(result.status, 0, `${command} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`)
  return result.stdout
}
try {
  const source = join(scratch, "source"),
    installed = join(scratch, "installed")
  mkdirSync(source)
  mkdirSync(installed)
  const manifest = JSON.parse(readFileSync(join(project, "package.json"), "utf8"))
  for (const name of [
    "package.json",
    "package-lock.json",
    "src",
    "LICENSE",
    "README.md",
    "docs/headless-cli.md",
    "docs/headless-cli-verification.md",
  ]) {
    assert.ok(existsSync(join(project, name)), `Required package input is missing: ${name}`)
    cpSync(join(project, name), join(source, name), { recursive: true })
  }
  symlinkSync(join(project, "node_modules"), join(source, "node_modules"), "dir")
  run(source, "npm", ["run", "build"])
  const packed = JSON.parse(
    run(source, "npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", scratch]),
  )
  assert.equal(packed.length, 1)
  const files = packed[0].files.map((file) => file.path)
  const entry = manifest.bin["pi-remote"]
  assert.ok(files.includes(entry), "The CLI entry must be in the tarball")
  assert.ok(
    (packed[0].files.find((file) => file.path === entry).mode & 0o111) !== 0,
    "The packed CLI entry must be executable",
  )
  assert.ok(files.includes("docs/headless-cli.md"))
  assert.ok(files.includes("docs/headless-cli-verification.md"))
  assert.ok(
    files.includes("dist/host/secret-worker.js"),
    "Bounded OS-store worker must ship with the command",
  )
  for (const file of files) {
    assert.ok(
      file === "package.json" ||
        file === "LICENSE" ||
        file === "README.md" ||
        file === "docs/headless-cli.md" ||
        file === "docs/headless-cli-verification.md" ||
        (file.startsWith("dist/") && /\.(?:js|map)$/.test(file)),
      `Unexpected package file: ${file}`,
    )
    assert.doesNotMatch(
      file,
      /(?:fixtures|\.test\.|node_modules|\.git|\.jsonl|\.pem|\.key|catalog|devices|requests)/,
    )
  }
  const tarball = join(scratch, packed[0].filename)
  run(installed, "npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    "--no-package-lock",
    tarball,
  ])
  const globalPrefix = join(scratch, "global")
  run(installed, "npm", [
    "install",
    "--global",
    "--prefix",
    globalPrefix,
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    tarball,
  ])
  const globalCommand = join(globalPrefix, "bin/pi-remote")
  assert.match(run(installed, globalCommand, ["--help"]), /Usage: pi-remote serve/)
  const command = join(installed, "node_modules/.bin/pi-remote")
  assert.ok(lstatSync(command).isSymbolicLink(), "npm must install the command link")
  const target = realpathSync(command)
  assert.ok((lstatSync(target).mode & 0o111) !== 0, "The installed entry must be executable")
  assert.ok(
    readFileSync(target, "utf8").startsWith("#!/usr/bin/env bun\n"),
    "The installed command must select Bun",
  )
  const help = run(installed, command, ["--help"])
  assert.match(help, /Usage: pi-remote serve/)
  assert.match(help, /No GUI or terminal forwarding/)
  const missingRuntime = spawnSync(command, ["--help"], {
    cwd: installed,
    encoding: "utf8",
    timeout: 15_000,
    env: { ...process.env, PATH: installed },
  })
  assert.notEqual(missingRuntime.status, 0)
  assert.match(missingRuntime.stderr, /bun/)
  assert.equal(missingRuntime.stdout, "")
  const invalid = spawnSync(
    command,
    ["serve", "--pi", join(scratch, "missing-pi"), "--listen", "127.0.0.1", "--port", "0"],
    { cwd: installed, encoding: "utf8", timeout: 15_000 },
  )
  assert.equal(invalid.status, 1)
  assert.match(invalid.stderr, /piLaunchFailed/)
  assert.match(invalid.stderr, /Pi entry was not found/)
  assert.equal(invalid.stdout, "")
  if (process.env.PI_REMOTE_TEST_OS_SECRETS === "1") {
    const state = join(scratch, "runtime-state")
    const started = spawnSync(
      command,
      [
        "serve",
        "--listen",
        "127.0.0.1",
        "--port",
        "0",
        "--pi",
        join(project, "src/fixtures/fake-pi.ts"),
        "--data-dir",
        state,
      ],
      { cwd: installed, encoding: "utf8", input: "quit\n", timeout: 15_000 },
    )
    try {
      assert.equal(started.status, 0, "Installed CLI must start and stop with the OS-store worker")
      assert.match(started.stdout, /Pi Remote listening/)
      assert.equal(started.stderr, "")
    } finally {
      const catalog = join(state, "catalog-id.json")
      if (existsSync(catalog)) {
        const { id } = JSON.parse(readFileSync(catalog, "utf8"))
        run(project, "bun", [
          "-e",
          `import {OSSecrets} from ${JSON.stringify(join(project, "src/host/secrets.ts"))}; const store=new OSSecrets(${JSON.stringify(id)}); try {await store.remove("tls-identity-v1")} finally {await store.close()}`,
        ])
      }
    }
  }
  console.log(
    `PASS: clean build, tarball allowlist and local/global npm installation (${process.platform}/${process.arch}).`,
  )
} finally {
  rmSync(scratch, { recursive: true, force: true })
}
