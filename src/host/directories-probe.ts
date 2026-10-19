// Run only in a child process with a reduced file limit.
import { dlopen, ptr } from "bun:ffi"
import assert from "node:assert/strict"
import {
  chmodSync,
  closeSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { DirectoryAccess, type DirectoryPage, type DirectoryRecord } from "./directories.ts"

const limits = dlopen(process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
  getrlimit: { args: ["i32", "ptr"], returns: "i32" },
})
const limit = Buffer.alloc(16)
assert.equal(limits.symbols.getrlimit(process.platform === "darwin" ? 8 : 7, ptr(limit)), 0)
assert.equal(limit.readBigUInt64LE(0), 128n)
assert.equal(limit.readBigUInt64LE(8), 128n)
limits.close()

const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-directory-limit-")))
const access = new DirectoryAccess(root)
const state = access as unknown as {
  nodes: Map<string, { record: DirectoryRecord }>
  cursors: Map<string, { created: number }>
  openNode(id: string): { record: DirectoryRecord; fd: number }
}
const held: number[] = []
function exhaust() {
  for (;;) {
    try {
      held.push(openSync("/dev/null", "r"))
    } catch (error) {
      assert.equal((error as NodeJS.ErrnoException).code, "EMFILE")
      return
    }
  }
}
function release() {
  for (const fd of held.splice(0)) closeSync(fd)
}
function capacity(): number {
  exhaust()
  const count = held.length
  release()
  return count
}
async function resolveRows(page: DirectoryPage) {
  for (const item of page.items) {
    assert.equal(item.fault, undefined)
    assert.equal(item.isDirectory, true)
    const record = await access.resolve(item.id)
    assert.equal(record.path, join(root, item.name))
    assert.deepEqual(await DirectoryAccess.validate(record), record)
  }
}
const result: Record<string, unknown> = { limit: 128 }
try {
  if (process.argv[2] === "browse") {
    // Warm the native iterator before measuring descriptor capacity.
    const empty = await access.list()
    const baseline = capacity()
    for (let index = 0; index < 160; index++) mkdirSync(join(root, `folder-${index}`))
    const seen = new Map<string, string>()
    let page = await access.list(empty.id)
    const initial = page.id
    for (;;) {
      // Check every returned capability before requesting another page.
      await resolveRows(page)
      for (const item of page.items) {
        assert(!seen.has(item.name))
        seen.set(item.name, item.id)
      }
      if (!page.next) break
      page = await access.list(page.id, page.next)
    }
    assert.equal(seen.size, 160)
    for (const [name, id] of seen) assert.equal((await access.resolve(id)).path, join(root, name))
    assert.equal(state.nodes.size, 162)
    assert.equal(capacity(), baseline)
    const refreshed = await access.list()
    assert.equal(refreshed.id, initial)
    assert.equal(refreshed.items.length, 100)
    await resolveRows(refreshed)
    for (const item of refreshed.items) assert.equal(item.id, seen.get(item.name))
    result.seen = seen.size
    result.faults = 0
    result.retained = state.nodes.size
    result.refreshed = refreshed.items.length
    const cached = refreshed.items[0]
    assert(cached)
    const path = join(root, cached.name)
    const saved = await access.resolve(cached.id)
    assert.equal((await access.atPath(path)).id, cached.id)
    symlinkSync(path, join(root, "alias"))
    assert.equal((await access.atPath(join(root, "alias"))).id, cached.id)
    result.alias = "stable"
    if (process.getuid?.() !== 0) {
      for (const mode of [0o000, 0o400, 0o100]) {
        chmodSync(path, mode)
        try {
          await assert.rejects(access.resolve(cached.id), { code: "permissionDenied" })
          await assert.rejects(access.list(cached.id), { code: "permissionDenied" })
          await assert.rejects(DirectoryAccess.validate(saved), { code: "permissionDenied" })
          let listing = await access.list(initial)
          let denied = listing.items.find((item) => item.name === cached.name)
          while (!denied && listing.next) {
            listing = await access.list(initial, listing.next)
            denied = listing.items.find((item) => item.name === cached.name)
          }
          assert.equal(denied?.fault, "permissionDenied")
          assert.equal(denied?.isDirectory, false)
        } finally {
          chmodSync(path, 0o700)
        }
      }
      result.permissions = "rejected"
    } else result.permissions = "skipped-root"
    renameSync(path, join(root, "moved"))
    mkdirSync(path)
    await assert.rejects(access.resolve(cached.id), { code: "staleDirectory" })
    await assert.rejects(DirectoryAccess.validate(saved), { code: "staleDirectory" })
    assert.notEqual((await access.atPath(path)).id, cached.id)
    // A symlink back to the same inode must not change a cached canonical path.
    rmSync(path, { recursive: true })
    symlinkSync(join(root, "moved"), path)
    await assert.rejects(access.resolve(cached.id), { code: "staleDirectory" })
    await assert.rejects(DirectoryAccess.validate(saved), { code: "staleDirectory" })
    result.replacement = "rejected"
  } else if (process.argv[2] === "cursors") {
    const empty = await access.list()
    const baseline = capacity()
    for (let index = 0; index < 205; index++) writeFileSync(join(root, `file-${index}`), "")
    const tokens: string[] = []
    for (let index = 0; index < 9; index++) {
      const page = await access.list(empty.id)
      assert(page.next)
      tokens.push(page.next)
      assert.equal(state.cursors.size, Math.min(index + 1, 8))
      assert.equal(capacity(), baseline - Math.min(index + 1, 8))
    }
    await assert.rejects(access.list(empty.id, tokens[0]), { code: "staleDirectory" })
    for (const token of tokens.slice(1)) {
      const middle = await access.list(empty.id, token)
      assert.equal(middle.items.length, 100)
      assert.equal(middle.next, token)
      const end = await access.list(empty.id, token)
      assert.equal(end.items.length, 5)
      assert.equal(end.next, undefined)
    }
    assert.equal(capacity(), baseline)
    for (let index = 0; index < 8; index++) await access.list(empty.id)
    assert.equal(capacity(), baseline - 8)
    for (const cursor of state.cursors.values()) cursor.created -= 60_000
    await access.list(empty.id)
    assert.equal(state.cursors.size, 1)
    assert.equal(capacity(), baseline - 1)
    for (let index = 0; index < 7; index++) await access.list(empty.id)
    assert.equal(capacity(), baseline - 8)
    access.close()
    assert.equal(state.cursors.size, 0)
    assert.equal(capacity(), baseline)
    access.close()
    assert.equal(capacity(), baseline)
    result.cursorBound = 8
    result.closedDescriptors = 8
  } else if (process.argv[2] === "pressure") {
    for (let index = 0; index < 160; index++) mkdirSync(join(root, `folder-${index}`))
    const selected = await access.list()
    assert(selected.next)
    const ids = [...state.nodes.keys()]
    const baseline = capacity()
    exhaust()
    await assert.rejects(access.resolve(selected.id), { code: "resourceLimit" })
    await assert.rejects(access.list(selected.id, selected.next), { code: "resourceLimit" })
    await assert.rejects(access.atPath(root), { code: "resourceLimit" })
    assert.deepEqual([...state.nodes.keys()], ids)
    release()
    assert.equal(capacity(), baseline)
    await resolveRows(selected)
    assert.equal((await access.resolve(selected.id)).path, root)
    // Force real exhaustion between exact-record validation and native duplication.
    const original = state.openNode.bind(access)
    state.openNode = (id) => {
      const current = original(id)
      exhaust()
      return current
    }
    try {
      await assert.rejects(access.list(selected.id), { code: "resourceLimit" })
    } finally {
      release()
      state.openNode = original
    }
    assert.equal(capacity(), baseline)
    assert.deepEqual([...state.nodes.keys()], ids)
    assert.equal(state.cursors.size, 1)
    const next = await access.list(selected.id, selected.next)
    assert.equal(next.items.length, 60)
    assert.equal(next.next, undefined)
    await resolveRows(next)
    const refreshed = await access.list(selected.id)
    assert.equal(refreshed.items.length, 100)
    await resolveRows(refreshed)
    for (const item of refreshed.items)
      assert.equal(item.id, selected.items.find((old) => old.name === item.name)?.id)
    result.pressure = "recovered"
  } else {
    throw new Error("Unknown directory probe")
  }
  access.close()
  assert.equal(state.nodes.size, 0)
  console.log(JSON.stringify(result))
} finally {
  release()
  access.close()
  rmSync(root, { recursive: true, force: true })
}
