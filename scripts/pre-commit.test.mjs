import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

const project = fileURLToPath(new URL("../", import.meta.url))
function run(cwd, command, args) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    timeout: 30_000,
    env: { ...process.env, HUSKY: "0", GIT_CONFIG_NOSYSTEM: "1" },
  })
  if (result.error) throw result.error
  return result
}
function git(root, ...args) {
  const result = run(root, "git", args)
  assert.equal(result.status, 0, result.stderr)
  return result.stdout
}
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "pi-hook-test-"))
  mkdirSync(join(root, "scripts"))
  mkdirSync(join(root, "src"))
  copyFileSync(join(project, "scripts/pre-commit.mjs"), join(root, "scripts/pre-commit.mjs"))
  copyFileSync(join(project, "biome.json"), join(root, "biome.json"))
  symlinkSync(join(project, "node_modules"), join(root, "node_modules"), "dir")
  writeFileSync(join(root, ".gitignore"), "node_modules\n")
  copyFileSync(join(project, "tsconfig.json"), join(root, "tsconfig.json"))
  writeFileSync(join(root, "src/staged.ts"), "export const staged = 1\n")
  git(root, "init", "--quiet")
  git(root, "add", "--", "src/staged.ts", "biome.json", "tsconfig.json", ".gitignore")
  return root
}
function unchanged(root, expectedStatus) {
  assert.ok(
    readFileSync(join(root, ".git/index")).equals(expectedStatus.index),
    "The hook must preserve the exact Git index bytes",
  )
  assert.equal(
    git(root, "status", "--porcelain=v1", "--untracked-files=all"),
    expectedStatus.status,
  )
  assert.equal(git(root, "write-tree"), expectedStatus.tree)
  assert.equal(readFileSync(join(root, "src/staged.ts"), "utf8"), expectedStatus.source)
}
function snapshot(root) {
  return {
    status: git(root, "status", "--porcelain=v1", "--untracked-files=all"),
    tree: git(root, "write-tree"),
    source: readFileSync(join(root, "src/staged.ts"), "utf8"),
    index: readFileSync(join(root, ".git/index")),
  }
}

test("Husky hook is exactly one check-only command", () => {
  assert.equal(
    readFileSync(join(project, ".husky/pre-commit"), "utf8"),
    "node ./scripts/pre-commit.mjs\n",
  )
})

test("hook runs from its own repository, succeeds and preserves worktree/index", () => {
  const root = fixture()
  try {
    writeFileSync(join(root, "src/staged.ts"), "export const staged = 2\n")
    const before = snapshot(root)
    const result = run(tmpdir(), process.execPath, [join(root, "scripts/pre-commit.mjs")])
    assert.equal(result.status, 0, result.stdout + result.stderr)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("staged Biome failure blocks without formatting or staging files", () => {
  const root = fixture()
  try {
    writeFileSync(join(root, "src/staged.ts"), "export const staged=1;\n")
    git(root, "add", "--", "src/staged.ts")
    const before = snapshot(root)
    const result = run(root, process.execPath, ["scripts/pre-commit.mjs"])
    assert.notEqual(result.status, 0)
    assert.match(result.stdout + result.stderr, /format|organize|check/i)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("a formatted worktree cannot conceal malformed staged formatting", () => {
  const root = fixture()
  try {
    writeFileSync(join(root, "src/staged.ts"), "export const staged=1;\n")
    git(root, "add", "--", "src/staged.ts")
    writeFileSync(join(root, "src/staged.ts"), "export const staged = 1\n")
    const before = snapshot(root)
    const result = run(root, process.execPath, ["scripts/pre-commit.mjs"])
    assert.notEqual(result.status, 0)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("hook ignores staged files outside the TypeScript package", () => {
  const root = fixture()
  try {
    mkdirSync(join(root, "Apps"))
    writeFileSync(
      join(root, "Apps/fixture.swift"),
      "Unrelated Swift source is not a Biome input.\n",
    )
    git(root, "add", "--", "Apps/fixture.swift")
    const before = snapshot(root)
    const result = run(root, process.execPath, ["scripts/pre-commit.mjs"])
    assert.equal(result.status, 0, result.stdout + result.stderr)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("missing local tools fail without installing dependencies", () => {
  const root = fixture()
  try {
    rmSync(join(root, "node_modules"))
    const before = snapshot(root)
    const result = run(root, process.execPath, ["scripts/pre-commit.mjs"])
    assert.notEqual(result.status, 0)
    assert.match(result.stdout + result.stderr, /MODULE_NOT_FOUND|Cannot find module/)
    assert.equal(existsSync(join(root, "node_modules")), false)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("whole-project typecheck rejects an unstaged TypeScript error without index changes", () => {
  const root = fixture()
  try {
    const broken = "export const broken: string = 1\n"
    writeFileSync(join(root, "src/unstaged.ts"), broken)
    const before = snapshot(root)
    const result = run(root, process.execPath, ["scripts/pre-commit.mjs"])
    assert.notEqual(result.status, 0)
    assert.match(result.stdout + result.stderr, /TS2322/)
    assert.equal(readFileSync(join(root, "src/unstaged.ts"), "utf8"), broken)
    unchanged(root, before)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
