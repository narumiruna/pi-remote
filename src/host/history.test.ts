import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import { appendFileSync, renameSync, writeFileSync } from "node:fs"
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  realpath,
  rm,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { readSessionHistory, SESSION_HISTORY_BYTES } from "./history.ts"
import { TRANSCRIPT_LIMITS, TranscriptReducer } from "./transcript.ts"

type Entry = Record<string, unknown>
const timestamp = "2026-01-01T00:00:00.000Z"
const time = new Date(timestamp).getTime()
let root: string
let folder: string
let file: string
const header = () => ({ type: "session", version: 3, id: "session-id", cwd: root, timestamp })
const entry = (type: string, id: string, parentId: string | null, fields: Entry = {}): Entry => ({
  type,
  id,
  parentId,
  timestamp,
  ...fields,
})
const user = (content: string) => ({ role: "user", content, timestamp: time })
const message = (id: string, parentId: string | null, content: string) =>
  entry("message", id, parentId, { message: user(content) })
const options = () => ({ folder, file, id: "session-id", cwd: root, required: true })
async function save(entries: Entry[]): Promise<void> {
  await writeFile(
    file,
    `${[header(), ...entries].map((item) => JSON.stringify(item)).join("\n")}\n`,
    { mode: 0o600 },
  )
}
beforeEach(async () => {
  root = await realpath(await mkdtemp(join(tmpdir(), "pi-history-test-")))
  folder = join(root, "session")
  await mkdir(folder, { mode: 0o700 })
  file = join(folder, "history.jsonl")
})
afterEach(async () => {
  await rm(root, { recursive: true, force: true })
})

test("last metadata entry selects its parent branch, not all messages in append order", async () => {
  await save([
    message("a", null, "root"),
    message("abandoned", "a", "must not display"),
    entry("branch_summary", "summary", "a", { fromId: "abandoned", summary: "branch summary" }),
    message("b", "summary", "active"),
    entry("session_info", "name", "b", { name: "Current session" }),
  ])
  const before = await Bun.file(file).text()
  expect(await readSessionHistory(options())).toEqual([
    user("root"),
    { role: "branchSummary", summary: "branch summary", fromId: "abandoned", timestamp: time },
    user("active"),
  ])
  expect(await Bun.file(file).text()).toBe(before)
  await save([
    message("old", null, "old root"),
    message("new", null, "new root"),
    entry("label", "label", "new", { targetId: "old", label: "Other root" }),
  ])
  expect(await readSessionHistory(options())).toEqual([user("new root")])
})

test("latest compaction retains its range, drops old summaries and pre-checkpoint system messages", async () => {
  const system = { role: "system", content: "checkpoint", timestamp: time }
  await save([
    message("a", null, "summarized"),
    message("b", "a", "kept"),
    entry("message", "system", "b", { message: { ...system, content: "old system" } }),
    entry("compaction", "c1", "system", {
      firstKeptEntryId: "b",
      summary: "old summary",
      tokensBefore: 100,
    }),
    message("d", "c1", "recent"),
    entry("compaction", "c2", "d", {
      firstKeptEntryId: "b",
      summary: "latest summary",
      tokensBefore: 200,
      systemMessage: system,
    }),
    message("e", "c2", "after"),
  ])
  expect(await readSessionHistory(options())).toEqual([
    system,
    { role: "compactionSummary", summary: "latest summary", tokensBefore: 200, timestamp: time },
    user("kept"),
    user("recent"),
    user("after"),
  ])
  await save([
    message("a", null, "retain none"),
    entry("compaction", "c", "a", {
      firstKeptEntryId: "c",
      summary: "only summary",
      tokensBefore: 1,
    }),
  ])
  expect(await readSessionHistory(options())).toEqual([
    { role: "compactionSummary", summary: "only summary", tokensBefore: 1, timestamp: time },
  ])
})

test("context edits are branch-relative and preserve roles; custom visibility stays unchanged", async () => {
  const assistant = {
    role: "assistant",
    content: [{ type: "text", text: "original" }],
    timestamp: time,
    stopReason: "stop",
  }
  await save([
    message("a", null, "omit me"),
    entry("message", "b", "a", { message: assistant }),
    entry("context_edit", "abandoned", "b", {
      targetId: "b",
      replacement: { content: "wrong branch" },
    }),
    entry("context_edit", "edit1", "b", { targetId: "b", replacement: { content: "first edit" } }),
    entry("context_edit", "edit2", "edit1", {
      targetId: "b",
      replacement: { content: "latest edit" },
    }),
    entry("context_edit", "omit", "edit2", { targetId: "a", replacement: null }),
    entry("custom_message", "custom", "omit", {
      customType: "fixture",
      content: "hidden",
      display: false,
      details: { private: true },
    }),
    entry("custom", "state", "custom", { data: "not a message" }),
  ])
  const messages = await readSessionHistory(options())
  expect(messages).toEqual([
    { ...assistant, content: [{ type: "text", text: "latest edit" }] },
    {
      role: "custom",
      customType: "fixture",
      content: "hidden",
      display: false,
      details: { private: true },
      timestamp: time,
    },
  ])
  const reducer = new TranscriptReducer()
  reducer.replaceHistory(messages ?? [])
  expect(reducer.messages.map((item) => item.text)).toEqual(["latest edit"])
})

test("LF-only framing accepts CRLF, final unterminated JSON and Pi-skipped malformed lines", async () => {
  await writeFile(
    file,
    `${JSON.stringify(header())}\r\n\nnot JSON\n${JSON.stringify(message("a", null, "é🙂\u2028\u2029"))}`,
  )
  const before = await Bun.file(file).text()
  expect(await readSessionHistory(options())).toEqual([user("é🙂\u2028\u2029")])
  expect(await Bun.file(file).text()).toBe(before)
})

test("saved cwd aliases resolve to the selected directory without accepting a linked session folder", async () => {
  const alias = join(root, "cwd-alias")
  await symlink(root, alias)
  await writeFile(
    file,
    `${JSON.stringify({ ...header(), cwd: alias })}\n${JSON.stringify(message("a", null, "alias"))}\n`,
  )
  expect(await readSessionHistory(options())).toEqual([user("alias")])
  const folderAlias = join(root, "folder-alias")
  await symlink(folder, folderAlias)
  await expect(
    readSessionHistory({
      ...options(),
      folder: folderAlias,
      file: join(folderAlias, "history.jsonl"),
    }),
  ).rejects.toMatchObject({ code: "unsafeStorage" })
})

test("more than 200 messages retain the reducer omission marker without keeping all bodies", async () => {
  await save(
    Array.from({ length: 300 }, (_, i) => message(`m${i}`, i ? `m${i - 1}` : null, `message ${i}`)),
  )
  const messages = await readSessionHistory(options())
  expect(messages).toHaveLength(TRANSCRIPT_LIMITS.messages + 1)
  const reducer = new TranscriptReducer()
  reducer.replaceHistory(messages ?? [])
  expect(reducer.omitted).toBe(true)
  expect(reducer.messages).toHaveLength(200)
  expect(reducer.messages[0]?.text).toBe("message 100")
})

test("new sessions can have no file; missing saved history and legacy headers fail closed", async () => {
  expect(await readSessionHistory({ ...options(), required: false })).toBeUndefined()
  expect(
    await readSessionHistory({ ...options(), file: undefined, required: false }),
  ).toBeUndefined()
  await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "unsafeStorage" })
  await expect(readSessionHistory({ ...options(), file: undefined })).rejects.toMatchObject({
    code: "incompatiblePi",
  })
  for (const version of [1, 2, 4]) {
    const original = `${JSON.stringify({ ...header(), version })}\n`
    await writeFile(file, original)
    await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "incompatiblePi" })
    expect(await Bun.file(file).text()).toBe(original)
  }
})

test("EOF growth and path replacement during a read reject the projection", async () => {
  for (const change of ["append", "replace"]) {
    await save([message("a", null, "original")])
    const allocationSize = Bun.file(file).size + 1
    const allocate = Buffer.alloc
    let changed = false
    const allocation = spyOn(Buffer, "alloc").mockImplementation((size, fill, encoding) => {
      if (!changed && size === allocationSize) {
        changed = true
        if (change === "append")
          appendFileSync(file, `${JSON.stringify(message("b", "a", "new"))}\n`)
        else {
          const replacement = join(folder, "replacement.jsonl")
          writeFileSync(replacement, `${JSON.stringify(header())}\n`, { mode: 0o600 })
          renameSync(replacement, file)
        }
      }
      return allocate(size, fill, encoding)
    })
    try {
      await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "conflict" })
      expect(changed).toBe(true)
    } finally {
      allocation.mockRestore()
    }
  }
})

test("oversized files, cycles, wrong identity and untrusted paths are rejected", async () => {
  await save([])
  await truncate(file, SESSION_HISTORY_BYTES + 1)
  await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "tooLarge" })
  await save([message("a", "a", "cycle")])
  await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "incompatiblePi" })
  await save([])
  await expect(readSessionHistory({ ...options(), id: "wrong" })).rejects.toMatchObject({
    code: "incompatiblePi",
  })
  await expect(readSessionHistory({ ...options(), cwd: "/wrong" })).rejects.toMatchObject({
    code: "incompatiblePi",
  })
  await expect(
    readSessionHistory({ ...options(), file: join(root, "outside.jsonl") }),
  ).rejects.toMatchObject({ code: "unsafeStorage" })
  await chmod(file, 0o666)
  await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "unsafeStorage" })
  await chmod(file, 0o600)
  await link(file, join(folder, "linked.jsonl"))
  await expect(readSessionHistory(options())).rejects.toMatchObject({ code: "unsafeStorage" })
  await rm(join(folder, "linked.jsonl"))
  await symlink(file, join(folder, "symlink.jsonl"))
  await expect(
    readSessionHistory({ ...options(), file: join(folder, "symlink.jsonl") }),
  ).rejects.toMatchObject({ code: "unsafeStorage" })
})
