import { afterEach, beforeEach, expect, test } from "bun:test"
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { PrivateStorage } from "./storage.ts"

let root: string
const opened: PrivateStorage[] = []
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "pi-storage-test-"))
})
afterEach(() => {
  for (const storage of opened.splice(0)) storage.close()
  rmSync(root, { recursive: true, force: true })
})
async function storage(path = join(root, "catalog")) {
  const result = await PrivateStorage.initialize(path)
  opened.push(result)
  return result
}

test("creates private metadata and preserves catalog UUID across restart", async () => {
  const first = await storage()
  expect(lstatSync(first.path).mode & 0o777).toBe(0o700)
  await first.writeJSON("state.json", { count: 1 })
  expect(lstatSync(join(first.path, "state.json")).mode & 0o777).toBe(0o600)
  await first.writeJSON("state.json", { count: 2 })
  expect(await first.readJSON<{ count: number }>("state.json")).toEqual({ count: 2 })
  expect(await first.readJSON("absent.json")).toBeNull()
  const uuid = first.catalogID
  first.close()
  const second = await storage()
  expect(second.catalogID).toBe(uuid)
  expect(readdirSync(second.path).sort()).toEqual(["catalog-id.json", "state.json"])
})

test("does not repair existing directory or file permissions", async () => {
  const path = join(root, "public")
  mkdirSync(path, { mode: 0o755 })
  await expect(PrivateStorage.initialize(path)).rejects.toMatchObject({ code: "unsafeStorage" })
  expect(lstatSync(path).mode & 0o777).toBe(0o755)
  const privateStore = await storage()
  writeFileSync(join(privateStore.path, "public.json"), "{}", { mode: 0o644 })
  await expect(privateStore.readJSON("public.json")).rejects.toMatchObject({
    code: "unsafeStorage",
  })
  await expect(privateStore.writeJSON("public.json", {})).rejects.toMatchObject({
    code: "unsafeStorage",
  })
  expect(lstatSync(join(privateStore.path, "public.json")).mode & 0o777).toBe(0o644)
})

test("rejects catalog symlinks, file symlinks and hard links without changing targets", async () => {
  const target = join(root, "target")
  mkdirSync(target, { mode: 0o700 })
  symlinkSync(target, join(root, "alias"))
  await expect(PrivateStorage.initialize(join(root, "alias"))).rejects.toMatchObject({
    code: "unsafeStorage",
  })
  const privateStore = await storage()
  const outside = join(root, "outside.json")
  writeFileSync(outside, '{"keep":true}', { mode: 0o600 })
  symlinkSync(outside, join(privateStore.path, "link.json"))
  linkSync(outside, join(privateStore.path, "hard.json"))
  for (const name of ["link.json", "hard.json"]) {
    await expect(privateStore.readJSON(name)).rejects.toMatchObject({ code: "unsafeStorage" })
    await expect(privateStore.writeJSON(name, {})).rejects.toMatchObject({ code: "unsafeStorage" })
  }
  expect(readFileSync(outside, "utf8")).toBe('{"keep":true}')
})

test("bounds reads and writes and rejects malformed metadata and traversal", async () => {
  const privateStore = await storage()
  await privateStore.writeJSON("large.json", { text: "x".repeat(2048) })
  await expect(privateStore.readJSON("large.json", 1024)).rejects.toMatchObject({
    code: "storageLimit",
  })
  await expect(privateStore.writeJSON("small.json", "x".repeat(2048), 1024)).rejects.toMatchObject({
    code: "storageLimit",
  })
  writeFileSync(join(privateStore.path, "broken.json"), "{", { mode: 0o600 })
  await expect(privateStore.readJSON("broken.json")).rejects.toMatchObject({
    code: "corruptStorage",
  })
  for (const name of ["../outside", "/absolute", "a/b", "", "a\0b"]) {
    await expect(privateStore.readJSON(name)).rejects.toMatchObject({ code: "invalidRequest" })
    await expect(privateStore.writeJSON(name, {})).rejects.toMatchObject({ code: "invalidRequest" })
  }
  writeFileSync(join(privateStore.path, "null.json"), "null", { mode: 0o600 })
  await expect(privateStore.readJSON("null.json")).rejects.toMatchObject({ code: "corruptStorage" })
  await expect(privateStore.writeJSON("not-a-record.json", null)).rejects.toMatchObject({
    code: "invalidRequest",
  })
  expect(readdirSync(privateStore.path).some((name) => name.endsWith(".tmp"))).toBe(false)
})

test("rejects corrupt catalog UUID without replacing it and releases failed initialization", async () => {
  const privateStore = await storage()
  await privateStore.writeJSON("catalog-id.json", { version: 9, id: "bad" })
  privateStore.close()
  await expect(PrivateStorage.initialize(privateStore.path)).rejects.toMatchObject({
    code: "corruptStorage",
  })
  expect(JSON.parse(readFileSync(join(privateStore.path, "catalog-id.json"), "utf8"))).toEqual({
    version: 9,
    id: "bad",
  })
  writeFileSync(
    join(privateStore.path, "catalog-id.json"),
    JSON.stringify({ version: 1, id: privateStore.catalogID }),
  )
  expect((await storage(privateStore.path)).catalogID).toBe(privateStore.catalogID)
})

test("rejects a second writer in-process", async () => {
  const first = await storage()
  await expect(PrivateStorage.initialize(first.path)).rejects.toMatchObject({ code: "catalogBusy" })
  first.close()
  expect((await storage(first.path)).catalogID).toBe(first.catalogID)
})

test("kernel lease rejects another process and releases after SIGKILL", async () => {
  const path = join(root, "process-catalog")
  const source = `import {PrivateStorage} from ${JSON.stringify(new URL("./storage.ts", import.meta.url).href)}; await PrivateStorage.initialize(${JSON.stringify(path)}); console.log("ready"); setInterval(()=>{},1000);`
  const child = Bun.spawn([process.execPath, "-e", source], { stdout: "pipe", stderr: "ignore" })
  try {
    const reader = child.stdout.getReader()
    const ready = await reader.read()
    reader.releaseLock()
    expect(new TextDecoder().decode(ready.value)).toContain("ready")
    await expect(PrivateStorage.initialize(path)).rejects.toMatchObject({ code: "catalogBusy" })
    child.kill("SIGKILL")
    await child.exited
    const reopened = await storage(path)
    expect(reopened.catalogID).toMatch(/^[0-9a-f-]{36}$/)
  } finally {
    child.kill("SIGKILL")
    await child.exited
  }
}, 10_000)

test("rejects directories and FIFOs as metadata without blocking", async () => {
  const privateStore = await storage()
  mkdirSync(join(privateStore.path, "directory.json"), { mode: 0o700 })
  const pipe = Bun.spawnSync(["/usr/bin/mkfifo", join(privateStore.path, "pipe.json")], {
    stdout: "ignore",
    stderr: "ignore",
  })
  expect(pipe.exitCode).toBe(0)
  for (const name of ["directory.json", "pipe.json"]) {
    await expect(privateStore.readJSON(name)).rejects.toMatchObject({ code: "unsafeStorage" })
    await expect(privateStore.writeJSON(name, {})).rejects.toMatchObject({ code: "unsafeStorage" })
  }
})

test("rejects changed catalog mode without changing permissions", async () => {
  const privateStore = await storage()
  chmodSync(privateStore.path, 0o755)
  await expect(privateStore.writeJSON("blocked.json", {})).rejects.toMatchObject({
    code: "unsafeStorage",
  })
  expect(lstatSync(privateStore.path).mode & 0o777).toBe(0o755)
})
