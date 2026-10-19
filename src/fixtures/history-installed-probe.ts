// Provider-free Pi 1.3.0 history checks. Uses only private temporary sessions.
import assert from "node:assert/strict"
import { randomUUID } from "node:crypto"
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { isAbsolute, join } from "node:path"
import { Coordinator } from "../host/coordinator.ts"
import { DirectoryAccess } from "../host/directories.ts"
import { readSessionHistory } from "../host/history.ts"
import { PiRPC, RPC_LIMITS } from "../host/rpc.ts"
import { PrivateStorage } from "../host/storage.ts"

type Entry = Record<string, unknown>
const entry = process.argv[2]
assert(entry && isAbsolute(entry), "Supply the absolute Pi 1.3.0 JavaScript entry")
const root = await realpath(await mkdtemp(join(tmpdir(), "pi-history-installed-")))
const cwd = join(root, "project")
const folder = join(root, "sessions")
const timestamp = "2026-01-01T00:00:00.000Z"
const id = randomUUID()
const header = { type: "session", version: 3, id, cwd, timestamp }
const user = (content: string) => ({ role: "user", content, timestamp: 1 })
const item = (type: string, id: string, parentId: string | null, fields: Entry = {}): Entry => ({
  type,
  id,
  parentId,
  timestamp,
  ...fields,
})
const message = (id: string, parentId: string | null, content: string) =>
  item("message", id, parentId, { message: user(content) })
const flags = [
  "--offline",
  "--no-extensions",
  "--no-skills",
  "--no-prompt-templates",
  "--no-themes",
  "--no-context-files",
  "--no-tools",
]
const env = {
  PI_CODING_AGENT_DIR: join(root, "agent"),
  PI_OFFLINE: "1",
  PI_SKIP_VERSION_CHECK: "1",
  PI_TELEMETRY: "0",
  PATH: "",
}
let child: PiRPC | undefined
let host: Coordinator | undefined
let storage: PrivateStorage | undefined
const originalRequest = PiRPC.prototype.request
try {
  await mkdir(cwd, { mode: 0o700 })
  await mkdir(folder, { mode: 0o700 })
  const cases: { name: string; version: number; entries: Entry[] }[] = [
    {
      name: "branch-and-metadata-leaf",
      version: 3,
      entries: [
        message("a", null, "root"),
        message("abandoned", "a", "not active"),
        item("branch_summary", "summary", "a", { summary: "left branch", fromId: "abandoned" }),
        message("b", "summary", "active"),
        item("session_info", "name", "b", { name: "Active branch" }),
      ],
    },
    {
      name: "nested-compaction-and-edits",
      version: 3,
      entries: [
        message("a", null, "summarized"),
        message("b", "a", "kept"),
        item("message", "system", "b", {
          message: { role: "system", content: "old prompt", timestamp: 1 },
        }),
        item("compaction", "c1", "system", {
          summary: "old",
          firstKeptEntryId: "b",
          tokensBefore: 100,
        }),
        message("d", "c1", "recent"),
        item("compaction", "c2", "d", {
          summary: "latest",
          firstKeptEntryId: "b",
          tokensBefore: 200,
          systemMessage: { role: "system", content: "checkpoint", timestamp: 1 },
        }),
        item("context_edit", "edit", "c2", { targetId: "b", replacement: { content: "edited" } }),
        item("custom_message", "custom", "edit", {
          customType: "probe",
          content: "hidden",
          display: false,
        }),
        item("context_edit", "omit", "custom", { targetId: "d", replacement: null }),
      ],
    },
    {
      name: "retain-none-new-root",
      version: 3,
      entries: [
        message("old-root", null, "old root"),
        message("new-root", null, "new root"),
        item("compaction", "c", "new-root", {
          summary: "retain none",
          firstKeptEntryId: "c",
          tokensBefore: 1,
        }),
      ],
    },
    {
      name: "legacy-v1",
      version: 1,
      entries: [
        { type: "message", timestamp, message: user("legacy user") },
        {
          type: "message",
          timestamp,
          message: {
            role: "hookMessage",
            customType: "probe",
            content: "legacy custom",
            display: true,
            timestamp: 1,
          },
        },
        {
          type: "compaction",
          timestamp,
          summary: "legacy summary",
          firstKeptEntryIndex: 1,
          tokensBefore: 100,
        },
      ],
    },
    {
      name: "legacy-v2",
      version: 2,
      entries: [
        message("a", null, "legacy root"),
        item("message", "hook", "a", {
          message: {
            role: "hookMessage",
            customType: "probe",
            content: "legacy custom",
            display: true,
            timestamp: 1,
          },
        }),
      ],
    },
  ]
  for (const history of cases) {
    const file = join(folder, `${history.name}.jsonl`)
    const before = `${[{ ...header, version: history.version }, ...history.entries]
      .map((value) => JSON.stringify(value))
      .join("\n")}\n`
    await writeFile(file, before, { mode: 0o600 })
    child = await PiRPC.start({
      entry,
      cwd,
      args: [...flags, "--session", file],
      env,
      onEvent: () => {},
    })
    const actual = (await child.request("get_messages")) as { messages: unknown[] }
    const afterMigration = await Bun.file(file).text()
    assert.equal(JSON.parse(afterMigration.split("\n")[0] as string).version, 3)
    assert.deepEqual(
      JSON.parse(
        JSON.stringify(await readSessionHistory({ folder, file, id, cwd, required: true })),
      ),
      actual.messages,
      history.name,
    )
    assert.equal(await Bun.file(file).text(), afterMigration)
    // Pi can append its initial thinking-level setting. Existing entries stay intact.
    if (history.version === 3) assert(afterMigration.startsWith(before))
    else assert.notEqual(afterMigration, before)
    await child.shutdown()
    child = undefined
  }

  storage = await PrivateStorage.initialize(join(root, "catalog"))
  host = await Coordinator.open({
    storage,
    directories: new DirectoryAccess(cwd),
    entry,
    piArgs: flags,
    env,
  })
  const send = (action: string, fields: Record<string, unknown> = {}) => {
    assert(host)
    return host.handle(
      {
        kind: "request",
        id: randomUUID().toUpperCase(),
        epoch: host.snapshot.epoch,
        session: host.snapshot.selected,
        action,
        fields,
      },
      randomUUID().toUpperCase(),
      () => true,
    )
  }
  const directory = await host.directories.list()
  assert.deepEqual(await send("createSession", { directory: directory.id }), { ok: {} })
  const selected = host.snapshot.selected
  const rpc = (host as unknown as { child: PiRPC }).child
  const state = (await rpc.request("get_state")) as { sessionFile: string; sessionId: string }
  assert.deepEqual(await send("closeSession"), { ok: {} })
  const messages = Array.from({ length: 140 }, (_, index) =>
    message(`m${index}`, index ? `m${index - 1}` : null, `${index}: ${"x".repeat(64 * 1024 - 16)}`),
  )
  assert(
    Buffer.byteLength(JSON.stringify(messages.map((value) => value.message))) >
      RPC_LIMITS.recordBytes,
  )
  const saved = `${[{ ...header, id: state.sessionId }, ...messages]
    .map((value) => JSON.stringify(value))
    .join("\n")}\n`
  await writeFile(state.sessionFile, saved, { mode: 0o600 })
  // Prove the real runtime's combined response exceeds the unchanged RPC limit.
  child = await PiRPC.start({
    entry,
    cwd,
    args: [...flags, "--session", state.sessionFile],
    env,
    onEvent: () => {},
  })
  await assert.rejects(child.request("get_messages"), { code: "unknownOutcome" })
  await child.shutdown()
  child = undefined
  const afterStartup = await Bun.file(state.sessionFile).text()
  assert(afterStartup.startsWith(saved))
  const commands: string[] = []
  PiRPC.prototype.request = function (...args) {
    commands.push(args[0])
    return originalRequest.apply(this, args)
  }
  assert.deepEqual(await send("resumeSession", { id: selected }), { ok: {} })
  assert.equal(host.snapshot.phase, "idle")
  assert.equal(host.snapshot.hasOlderMessages, true)
  assert(host.snapshot.messages.at(-1)?.text.startsWith("139: "))
  const resumed = (await (host as unknown as { child: PiRPC }).child.request("get_state")) as {
    messageCount: number
  }
  assert.equal(resumed.messageCount, 140)
  assert(!commands.includes("prompt") && !commands.includes("get_messages"))
  assert.equal(await Bun.file(state.sessionFile).text(), afterStartup)
  await host.shutdown()
  host = undefined
  storage = await PrivateStorage.initialize(join(root, "startup-catalog"))
  const startupExtension = join(root, "startup-extension.ts")
  await writeFile(
    startupExtension,
    `export default function(pi) {
    pi.on("session_start", () => {
      pi.sendMessage({ customType: "startup", content: "Startup-only history probe", display: true }, { triggerTurn: false })
    })
  }\n`,
    { mode: 0o600 },
  )
  host = await Coordinator.open({
    storage,
    directories: new DirectoryAccess(cwd),
    entry,
    piArgs: [
      ...flags.filter((flag) => flag !== "--no-extensions"),
      "--extension",
      startupExtension,
    ],
    env,
  })
  commands.length = 0
  const fresh = await host.directories.list()
  assert.deepEqual(await send("createSession", { directory: fresh.id }), { ok: {} })
  assert(host.snapshot.messages.some((value) => value.text === "Startup-only history probe"))
  assert(commands.includes("get_messages") && !commands.includes("prompt"))
  const startupState = (await (host as unknown as { child: PiRPC }).child.request("get_state")) as {
    sessionFile: string
    messageCount: number
  }
  assert.equal(startupState.messageCount, 1)
  assert.equal(await Bun.file(startupState.sessionFile).exists(), false)
  console.log(
    "PASS: Pi 1.3.0 branch/compaction/edit projections, Pi-managed v1/v2 migration, >8MiB saved resume and fresh in-memory startup display; saved context unchanged, no provider prompt or prompt replay.",
  )
} finally {
  PiRPC.prototype.request = originalRequest
  await child?.shutdown()
  await host?.shutdown()
  storage?.close()
  await rm(root, { recursive: true, force: true })
}
