import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs"
import { homedir, tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { DirectoryAccess, type DirectoryRecord } from "./directories.ts"

let root: string
const browsers: DirectoryAccess[] = []
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "pi-directory-test-")))
})
afterEach(() => {
  for (const browser of browsers.splice(0)) browser.close()
  rmSync(root, { recursive: true, force: true })
})
function browser(path = root) {
  const value = new DirectoryAccess(path)
  browsers.push(value)
  return value
}

test("launch src/projects folders are defaults, and parent browsing is unrestricted", async () => {
  for (const name of ["src", "projects"]) {
    const path = join(root, name)
    mkdirSync(path)
    mkdirSync(join(path, "nested"))
    const access = browser(path)
    const initial = await access.list()
    expect(initial.path).toBe(path)
    expect(initial.items.find((item) => item.name === "nested")?.isDirectory).toBe(true)
    expect(initial.parent).toBeDefined()
    const parent = await access.list(initial.parent)
    expect(parent.path).toBe(root)
    expect((await access.list(parent.parent)).path).toBe(dirname(root))
    expect(await access.resolve(initial.id)).toEqual(await DirectoryAccess.identify(path))
  }
})

test("explicit absolute and home paths resolve without shell expansion or creation", async () => {
  const access = browser()
  mkdirSync(join(root, "space name"))
  expect((await access.atPath(join(root, "space name"))).path).toBe(join(root, "space name"))
  expect((await access.atPath("~")).path).toBe(realpathSync(homedir()))
  for (const path of ["", "relative", "~other", "$(pwd)", "a\0b", "/".repeat(4097)])
    await expect(access.atPath(path)).rejects.toMatchObject({ code: "invalidRequest" })
  await expect(access.atPath(join(root, "not-created"))).rejects.toMatchObject({
    code: "staleDirectory",
  })
})

test("directory symlinks resolve to canonical identity, broken links cannot authorize launch", async () => {
  mkdirSync(join(root, "real"))
  symlinkSync(join(root, "real"), join(root, "alias"))
  symlinkSync(join(root, "missing"), join(root, "broken"))
  symlinkSync(join(root, "loop"), join(root, "loop"))
  writeFileSync(join(root, "file.txt"), "data")
  const access = browser()
  const page = await access.list()
  const real = page.items.find((item) => item.name === "real")
  const alias = page.items.find((item) => item.name === "alias")
  expect(alias?.id).toBe(real?.id)
  expect(page.items.find((item) => item.name === "file.txt")?.isDirectory).toBe(false)
  for (const name of ["broken", "loop"]) {
    const item = page.items.find((entry) => entry.name === name)
    expect(item?.fault).toBeDefined()
    await expect(access.resolve(item?.id ?? "")).rejects.toMatchObject({ code: "staleDirectory" })
  }
  expect((await access.atPath(join(root, "alias"))).path).toBe(join(root, "real"))
})

test("deleted, moved and replaced directories invalidate IDs and persisted records", async () => {
  const path = join(root, "selected")
  mkdirSync(path)
  const access = browser()
  const selected = await access.atPath(path)
  const saved = await access.resolve(selected.id)
  await expect(DirectoryAccess.validate(saved)).resolves.toEqual(saved)
  renameSync(path, join(root, "moved"))
  mkdirSync(path)
  await expect(access.resolve(selected.id)).rejects.toMatchObject({ code: "staleDirectory" })
  await expect(DirectoryAccess.validate(saved)).rejects.toMatchObject({ code: "staleDirectory" })
  const replacement = await access.atPath(path)
  expect(replacement.id).not.toBe(selected.id)
  rmSync(path, { recursive: true })
  await expect(access.list(replacement.id)).rejects.toMatchObject({ code: "staleDirectory" })
  access.close()
  await expect(access.resolve(selected.id)).rejects.toMatchObject({ code: "staleDirectory" })
})

test("cursor start uses the validated descriptor and rejects a path replaced before enumeration", async () => {
  const selected = join(root, "selected")
  mkdirSync(selected)
  const access = browser(selected)
  const empty = await access.list()
  for (let index = 0; index < 101; index++) writeFileSync(join(selected, `original-${index}`), "")
  const state = access as unknown as {
    openNode(id: string): { record: DirectoryRecord; fd: number }
    cursors: Map<string, { iterator: { readSync(): { name: string } | null } }>
  }
  const original = state.openNode.bind(access)
  let replace = true
  state.openNode = (id) => {
    const current = original(id)
    if (replace) {
      replace = false
      renameSync(selected, join(root, "moved"))
      mkdirSync(selected)
      writeFileSync(join(selected, "replacement"), "")
    }
    return current
  }
  const names = new Set<string>()
  const save = state.cursors.set.bind(state.cursors)
  const cursorSet = spyOn(state.cursors, "set").mockImplementation((token, cursor) => {
    const read = cursor.iterator.readSync.bind(cursor.iterator)
    cursor.iterator.readSync = () => {
      const entry = read()
      if (entry) names.add(entry.name)
      return entry
    }
    return save(token, cursor)
  })
  try {
    await expect(access.list(empty.id)).rejects.toMatchObject({ code: "staleDirectory" })
    expect(names.size).toBe(100)
    expect([...names].every((name) => name.startsWith("original-"))).toBe(true)
    expect(state.cursors.size).toBe(0)
  } finally {
    state.openNode = original
    cursorSet.mockRestore()
  }
})

test("pagination examines at most 100 entries and independent cursors do not share offsets", async () => {
  for (let index = 0; index < 205; index++) writeFileSync(join(root, `file-${index}`), "")
  const access = browser()
  const first = await access.list()
  const other = await access.list(first.id)
  expect(first.items.length).toBe(100)
  expect(other.items.map((item) => item.name)).toEqual(first.items.map((item) => item.name))
  const seen = new Set(first.items.map((item) => item.name))
  let next = first.next
  while (next) {
    const page = await access.list(first.id, next)
    expect(page.items.length).toBeLessThanOrEqual(100)
    for (const item of page.items) {
      expect(seen.has(item.name)).toBe(false)
      seen.add(item.name)
    }
    next = page.next
  }
  expect(seen.size).toBe(205)
  await expect(access.list(first.id, first.next)).rejects.toMatchObject({ code: "staleDirectory" })
})

test("cursor count, directory binding and 60-second TTL are enforced", async () => {
  for (let index = 0; index < 101; index++) writeFileSync(join(root, `file-${index}`), "")
  mkdirSync(join(root, "nested"))
  const access = browser()
  const clock = spyOn(performance, "now").mockReturnValue(1000)
  try {
    const first = await access.list()
    const nested = await access.atPath(join(root, "nested"))
    await expect(access.list(nested.id, first.next)).rejects.toMatchObject({
      code: "staleDirectory",
    })
    for (let index = 0; index < 8; index++) await access.list(first.id)
    await expect(access.list(first.id, first.next)).rejects.toMatchObject({
      code: "staleDirectory",
    })
    const recent = await access.list(first.id)
    clock.mockReturnValue(61_000)
    await expect(access.list(first.id, recent.next)).rejects.toMatchObject({
      code: "staleDirectory",
    })
  } finally {
    clock.mockRestore()
  }
})

test("the directory capability registry never exceeds 4096 entries", async () => {
  for (let index = 0; index < 4100; index++) mkdirSync(join(root, `folder-${index}`))
  const access = browser()
  let page = await access.list()
  for (;;) {
    for (const item of page.items) await expect(access.resolve(item.id)).resolves.toBeDefined()
    if (!page.next) break
    page = await access.list(page.id, page.next)
  }
  const state = access as unknown as { nodes: Map<string, unknown> }
  expect(state.nodes.size).toBe(4096)
  expect((await access.resolve(page.id)).path).toBe(root)
}, 30_000)

test("metadata LRU keeps active cursor IDs and cached aliases within the 4096-entry bound", async () => {
  const pinned = join(root, "pinned")
  mkdirSync(pinned)
  for (let index = 0; index < 101; index++) writeFileSync(join(pinned, `file-${index}`), "")
  for (let index = 0; index < 4096; index++) mkdirSync(join(root, `folder-${index}`))
  const access = browser(pinned)
  const state = access as unknown as {
    nodes: Map<string, unknown>
    register(path: string): string
  }
  const first = await access.list()
  expect(first.next).toBeDefined()
  const oldest = state.register(join(root, "folder-0"))
  const evicted = state.register(join(root, "folder-1"))
  for (let index = 2; index < 4094; index++) state.register(join(root, `folder-${index}`))
  expect(state.nodes.size).toBe(4096)
  await access.resolve(oldest)
  state.register(join(root, "folder-4094"))
  state.register(join(root, "folder-4095"))
  expect(state.nodes.size).toBe(4096)
  expect(state.nodes.has(first.id)).toBe(true)
  expect((await access.resolve(oldest)).path).toBe(join(root, "folder-0"))
  await expect(access.resolve(evicted)).rejects.toMatchObject({ code: "staleDirectory" })
  symlinkSync(join(root, "folder-0"), join(root, "alias"))
  expect(state.register(join(root, "alias"))).toBe(oldest)
  expect(state.register(join(root, "folder-1"))).not.toBe(evicted)
  const next = await access.list(first.id, first.next)
  expect(next.items).toHaveLength(1)
  expect(next.next).toBeUndefined()
  expect(state.nodes.size).toBe(4096)
}, 30_000)

for (const mode of ["browse", "cursors", "pressure"]) {
  test.skipIf(!["linux", "darwin"].includes(process.platform))(
    `real child RLIMIT_NOFILE 128: ${mode}`,
    async () => {
      const child = Bun.spawn(
        [
          "/bin/bash",
          "-c",
          'ulimit -S -n 128 && ulimit -H -n 128 && exec "$1" "$2" "$3"',
          "directory-probe",
          process.execPath,
          join(import.meta.dir, "directories-probe.ts"),
          mode,
        ],
        { stdout: "pipe", stderr: "pipe" },
      )
      const [stdout, stderr, exit] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ])
      expect({ exit, stderr }).toEqual({ exit: 0, stderr: "" })
      const result = JSON.parse(stdout)
      expect(result.limit).toBe(128)
      if (mode === "browse") {
        expect(result.seen).toBe(160)
        expect(result.faults).toBe(0)
        expect(result.retained).toBe(162)
        expect(result.refreshed).toBe(100)
        expect(result.alias).toBe("stable")
        expect(result.replacement).toBe("rejected")
        expect(result.permissions).toBe(process.getuid?.() === 0 ? "skipped-root" : "rejected")
      } else if (mode === "cursors") {
        expect(result.cursorBound).toBe(8)
        expect(result.closedDescriptors).toBe(8)
      } else expect(result.pressure).toBe("recovered")
    },
    30_000,
  )
}

test.skipIf(process.getuid?.() === 0)(
  "lost read/search permission blocks selection and persisted-directory validation",
  async () => {
    const path = join(root, "denied")
    mkdirSync(path)
    const access = browser()
    const page = await access.atPath(path)
    const saved = await access.resolve(page.id)
    chmodSync(path, 0o000)
    try {
      await expect(access.resolve(page.id)).rejects.toMatchObject({ code: "permissionDenied" })
      await expect(DirectoryAccess.validate(saved)).rejects.toMatchObject({
        code: "permissionDenied",
      })
    } finally {
      chmodSync(path, 0o700)
    }
  },
)

test.skipIf(process.platform !== "linux")(
  "Linux procfs without statx birth time is unsupported, not weakened",
  async () => {
    await expect(DirectoryAccess.identify("/proc")).rejects.toMatchObject({
      code: "unsupportedFeature",
    })
    const access = browser("/")
    const page = await access.list()
    const proc = page.items.find((item) => item.name === "proc")
    expect(proc?.fault).toBe("unsupportedFeature")
    await expect(access.resolve(proc?.id ?? "")).rejects.toMatchObject({ code: "staleDirectory" })
  },
)
