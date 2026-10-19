import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { required, until } from "../fixtures/client.ts"
import { Coordinator } from "./coordinator.ts"
import { DirectoryAccess } from "./directories.ts"
import { type ClientPacket, enumValue, packet } from "./protocol.ts"
import { type PiRPC, RPCError } from "./rpc.ts"
import { Fault, PrivateStorage } from "./storage.ts"

type Request = Extract<ClientPacket, { kind: "request" }>
let root: string
let storage: PrivateStorage
let host: Coordinator
const device = randomUUID().toUpperCase()
const entry = resolve("src/fixtures/fake-pi.ts")
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "pi-coordinator-test-"))
})
afterEach(async () => {
  await host?.shutdown()
  storage?.close()
  await rm(root, { recursive: true, force: true })
})
async function open(parent = "src"): Promise<void> {
  await mkdir(join(root, parent, "project"), { recursive: true })
  storage = await PrivateStorage.initialize(join(root, "catalog"))
  host = await Coordinator.open({
    storage,
    directories: new DirectoryAccess(join(root, parent)),
    entry,
  })
}
function request(
  action: string,
  fields: Record<string, unknown> = {},
  context: Partial<Request> = {},
): Request {
  return {
    kind: "request",
    id: randomUUID().toUpperCase(),
    epoch: host.snapshot.epoch,
    session: host.snapshot.selected,
    action,
    fields,
    ...context,
  }
}
function send(
  action: string,
  fields: Record<string, unknown> = {},
  context: Partial<Request> = {},
) {
  return host.handle(request(action, fields, context), device, () => true)
}
async function create(): Promise<void> {
  const page = await host.directories.atPath(join(root, "src", "project"))
  expect(await send("createSession", { directory: page.id })).toEqual({ ok: {} })
}
function rpc(): PiRPC {
  return (host as unknown as { child: PiRPC }).child
}
async function events(...items: Record<string, unknown>[]): Promise<void> {
  await rpc().request("fixture_events", { events: items })
}

for (const parent of ["src", "projects"]) {
  test(`${parent} launch folder browses without starting Pi; nested selection saves directory`, async () => {
    await open(parent)
    expect(host.snapshot.sessions).toEqual([])
    expect(host.snapshot.selected).toBeUndefined()
    const result = (await send("directories")) as {
      directories: { _0: { path: string; parent: string; items: { id: string; name: string }[] } }
    }
    expect(result.directories._0.path).toBe(await realpath(join(root, parent)))
    expect(result.directories._0.parent).toBeString()
    const folder = required(result.directories._0.items.find((item) => item.name === "project"))
    expect(await send("createSession", { directory: folder.id })).toEqual({ ok: {} })
    expect(host.snapshot.sessions[0]?.directory).toBe(await realpath(join(root, parent, "project")))
    expect(host.snapshot.phase).toBe("idle")
  })
}

test("close and explicit reopen preserve history and selected working directory", async () => {
  await open()
  await create()
  const id = required(host.snapshot.selected)
  const text = "CLI fixture: write acceptance.txt with CLI acceptance\n"
  expect(await send("prompt", { text, delivery: "prompt" })).toEqual({ ok: {} })
  await until(() => host.snapshot.phase === "idle")
  expect(await Bun.file(join(root, "src", "project", "acceptance.txt")).text()).toBe(
    "CLI acceptance\n",
  )
  expect(await send("closeSession")).toEqual({ ok: {} })
  expect(host.snapshot.selected).toBeUndefined()
  expect(await send("resumeSession", { id })).toEqual({ ok: {} })
  expect(host.snapshot.selected).toBe(id)
  expect(host.snapshot.sessions[0]?.directory).toBe(await realpath(join(root, "src", "project")))
  expect(host.snapshot.messages.filter((message) => message.role === "user")).toHaveLength(1)
  expect(((await rpc().request("get_state")) as { prompts: number }).prompts).toBe(0)
})

test("active close and switches are busy; Stop clears steering and follow-up before idle", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  await until(() => host.snapshot.phase === "working")
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  expect(await send("resumeSession", { id: host.snapshot.selected })).toEqual({
    failure: { _0: "busy" },
  })
  expect(await send("prompt", { text: "steering", delivery: "steer" })).toEqual({ ok: {} })
  expect(await send("prompt", { text: "follow-up", delivery: "followUp" })).toEqual({ ok: {} })
  expect(
    ((await rpc().request("get_state")) as { pendingMessageCount: number }).pendingMessageCount,
  ).toBe(2)
  expect(await send("stop")).toEqual({ ok: {} })
  expect(host.snapshot.phase).toBe("idle")
  expect(host.snapshot.pendingMessages).toBe(0)
  expect(
    ((await rpc().request("get_state")) as { pendingMessageCount: number }).pendingMessageCount,
  ).toBe(0)
  expect(await send("closeSession")).toEqual({ ok: {} })
})

test("wrong epoch, stale session and unsupported actions have no Pi or catalog effect", async () => {
  await open()
  await create()
  const before = await Bun.file(join(storage.path, "sessions.json")).text()
  const fields = { text: "must not run", delivery: "prompt" }
  expect(await send("prompt", fields, { epoch: randomUUID().toUpperCase() })).toEqual({
    failure: { _0: "unknownOutcome" },
  })
  expect(await send("prompt", fields, { session: randomUUID().toUpperCase() })).toEqual({
    failure: { _0: "conflict" },
  })
  for (const action of ["bash", "compact", "newSession", "rename", "importSession"]) {
    expect(await send(action)).toEqual({ failure: { _0: "unsupportedFeature" } })
  }
  expect(await Bun.file(join(storage.path, "sessions.json")).text()).toBe(before)
  expect(((await rpc().request("get_state")) as { prompts: number }).prompts).toBe(0)
  expect(host.snapshot.messages).toEqual([])
})

test("pending duplicate is unknown, concurrent mutation busy, completed duplicate does not redispatch", async () => {
  await open()
  await create()
  const original = storage.writeJSON.bind(storage)
  let release!: () => void
  let entered = false
  const gate = new Promise<void>((resolveGate) => {
    release = resolveGate
  })
  const write = spyOn(storage, "writeJSON").mockImplementation(async (name, data, limit) => {
    if (name === "requests.json" && !entered) {
      entered = true
      await gate
    }
    return original(name, data, limit)
  })
  const prompt = request("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })
  const first = host.handle(prompt, device, () => true)
  try {
    await until(() => entered)
    expect(await host.handle(prompt, device, () => true)).toEqual({
      failure: { _0: "unknownOutcome" },
    })
    expect(await send("thinking", { level: "high" })).toEqual({ failure: { _0: "busy" } })
    release()
    expect(await first).toEqual({ ok: {} })
    expect(await host.handle(prompt, device, () => true)).toEqual({ ok: {} })
    expect(
      await host.handle(
        { ...prompt, fields: { ...prompt.fields, text: "different" } },
        device,
        () => true,
      ),
    ).toEqual({ failure: { _0: "conflict" } })
    expect(((await rpc().request("get_state")) as { prompts: number }).prompts).toBe(1)
  } finally {
    release()
    await first
    write.mockRestore()
  }
})

test("lost authorization during durable acceptance prevents prompt dispatch", async () => {
  await open()
  await create()
  let authorized = true
  const original = storage.writeJSON.bind(storage)
  const write = spyOn(storage, "writeJSON").mockImplementation(async (name, data, limit) => {
    await original(name, data, limit)
    if (name === "requests.json") authorized = false
  })
  try {
    expect(
      await host.handle(
        request("prompt", { text: "private", delivery: "prompt" }),
        device,
        () => authorized,
      ),
    ).toEqual({ failure: { _0: "unauthorized" } })
    expect(((await rpc().request("get_state")) as { prompts: number }).prompts).toBe(0)
  } finally {
    write.mockRestore()
  }
})

test("restart marks interrupted work and never autoactivates or replays prompts", async () => {
  await open()
  await create()
  const id = required(host.snapshot.selected),
    epoch = host.snapshot.epoch
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  await until(() => host.snapshot.phase === "working")
  await host.shutdown()
  storage = await PrivateStorage.initialize(join(root, "catalog"))
  host = await Coordinator.open({
    storage,
    directories: new DirectoryAccess(join(root, "src")),
    entry,
  })
  expect(host.snapshot.epoch).not.toBe(epoch)
  expect(host.snapshot.selected).toBeUndefined()
  expect(host.snapshot.sessions).toMatchObject([{ id, interrupted: true }])
  expect(host.snapshot.messages).toEqual([])
  expect(await send("resumeSession", { id })).toEqual({ ok: {} })
  expect(host.snapshot.messages.filter((message) => message.role === "user")).toHaveLength(1)
  expect(((await rpc().request("get_state")) as { prompts: number }).prompts).toBe(0)
})

test("handled prompts remain quiet; agent_end does not replace agent_settled", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "/handled", delivery: "prompt" })).toEqual({ ok: {} })
  expect(host.snapshot.phase).toBe("idle")
  expect(host.snapshot.messages).toEqual([])
  expect(host.snapshot.sessions[0]?.interrupted).toBe(false)
  await events({ type: "agent_start" }, { type: "agent_end", messages: [], willRetry: false })
  await until(() => host.snapshot.phase === "working")
  expect(host.snapshot.phase).toBe("working")
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  await events({ type: "agent_settled", aborted: false })
  await until(() => host.snapshot.phase === "idle")
  expect(host.snapshot.phase).toBe("idle")
})

test("accepted work blocks close before agent_start reaches the coordinator", async () => {
  await open()
  await create()
  const child = rpc(),
    original = child.request.bind(child)
  const dispatch = spyOn(child, "request").mockImplementation(async (command, fields, options) => {
    if (command === "prompt") return { disposition: "started" }
    return original(command, fields, options)
  })
  try {
    expect(await send("prompt", { text: "accepted before event", delivery: "prompt" })).toEqual({
      ok: {},
    })
    expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
    expect(await send("prompt", { text: "second", delivery: "prompt" })).toEqual({
      failure: { _0: "busy" },
    })
  } finally {
    dispatch.mockRestore()
  }
})

test("Stop fences a prompt still waiting for durable catalog acceptance", async () => {
  await open()
  await create()
  const original = storage.writeJSON.bind(storage)
  let release: () => void = () => {}
  let blocked = false
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const writes = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "sessions.json" && !blocked) {
      blocked = true
      await gate
    }
    return original(name, value, maximum)
  })
  const pending = send("prompt", { text: "Must not start after Stop", delivery: "prompt" })
  await until(() => blocked)
  const stopped = send("stop")
  await until(() => host.snapshot.phase === "stopping" || host.snapshot.phase === "idle")
  await Bun.sleep(10)
  release()
  expect(await pending).toEqual({ failure: { _0: "cancelled" } })
  expect(await stopped).toEqual({ ok: {} })
  expect(((await rpc().request("get_state")) as Record<string, unknown>).prompts).toBe(0)
  writes.mockRestore()
})

test("shutdown owns and stops a child during its initial RPC handshake", async () => {
  await open()
  ;(host as unknown as { env: Record<string, string> }).env = { RPC_FIXTURE_MODE: "startup-hang" }
  const page = await host.directories.atPath(join(root, "src", "project"))
  const creating = send("createSession", { directory: page.id })
  await until(() => !!(host as unknown as { child?: PiRPC }).child?.childPid)
  const start = performance.now()
  await host.shutdown()
  expect(performance.now() - start).toBeLessThan(3000)
  expect(await creating).toEqual({ failure: { _0: "unknownOutcome" } })
})

for (const delivery of ["prompt", "steer", "followUp"]) {
  test(`Stop owns unresolved Pi ${delivery} preflight before reporting stopped`, async () => {
    await open()
    await create()
    if (delivery !== "prompt")
      expect(
        await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" }),
      ).toEqual({ ok: {} })
    const child = rpc(),
      pid = required(child.childPid)
    const waiting = send("prompt", { text: "CLI fixture: delayed preflight", delivery })
    await until(() => (host as unknown as { pendingInputs: number }).pendingInputs === 1)
    expect(await send("stop")).toEqual({ ok: {} })
    // EOF may let Pi acknowledge before it exits. Either acceptance or an unknown acknowledgement is explicit; no process may survive Stop.
    const outcome = await waiting
    if ("failure" in outcome) expect(outcome).toEqual({ failure: { _0: "unknownOutcome" } })
    else expect(outcome).toEqual({ ok: {} })
    expect(() => process.kill(pid, 0)).toThrow()
    expect(host.snapshot.phase).toBe("interrupted")
    expect(host.snapshot.notices.some((value) => value.includes("unknown outcome"))).toBe(true)
  })
}

test("catalog failure cannot invent idle or permit Close while Pi is still working", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const original = storage.writeJSON.bind(storage)
  let failed = false
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "sessions.json" && !failed) {
      failed = true
      throw Object.assign(new Error("fixture disk failure"), { code: "EIO" })
    }
    return original(name, value, maximum)
  })
  expect(await send("prompt", { text: "Never dispatched steering", delivery: "steer" })).toEqual({
    failure: { _0: "storageFailure" },
  })
  expect(host.snapshot.phase).toBe("working")
  expect(host.snapshot.error).toBe("unknownOutcome")
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  expect(((await rpc().request("get_state")) as Record<string, unknown>).isStreaming).toBe(true)
  mocked.mockRestore()
  expect(await send("stop")).toEqual({ ok: {} })
})

test("Stop cancels activation before any Pi child exists", async () => {
  await open()
  const page = await host.directories.list()
  const original = DirectoryAccess.validate.bind(DirectoryAccess)
  let calls = 0,
    reached = false,
    release = () => {}
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const mocked = spyOn(DirectoryAccess, "validate").mockImplementation(async (record) => {
    if (++calls === 2) {
      reached = true
      await gate
    }
    return original(record)
  })
  const creating = send("createSession", { directory: page.id })
  try {
    await until(() => reached)
    expect(host.snapshot.phase).toBe("starting")
    expect(rpc()).toBeUndefined()
    expect(await send("stop")).toEqual({ ok: {} })
    release()
    expect(await creating).toEqual({ failure: { _0: "cancelled" } })
    expect(rpc()).toBeUndefined()
    expect(host.snapshot.phase).toBe("interrupted")
  } finally {
    release()
    mocked.mockRestore()
  }
})

test("Stop fences a creation still saving metadata for another selected session", async () => {
  await open()
  await create()
  const selected = host.snapshot.selected,
    child = rpc()
  const page = await host.directories.list()
  const original = storage.writeJSON.bind(storage)
  let reached = false,
    release = () => {}
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "sessions.json" && !reached) {
      reached = true
      await gate
    }
    return original(name, value, maximum)
  })
  const creating = send("createSession", { directory: page.id })
  try {
    await until(() => reached)
    const stopped = send("stop")
    await until(() => (host as unknown as { stopRevision: number }).stopRevision > 0)
    release()
    expect(await stopped).toEqual({ ok: {} })
    expect(await creating).toEqual({ failure: { _0: "cancelled" } })
    expect(host.snapshot.selected).toBe(selected)
    expect(rpc()).toBe(child)
  } finally {
    release()
    mocked.mockRestore()
  }
})

test("a blocked extension answer releases Stop admission with an explicit unknown outcome", async () => {
  await open()
  await create()
  await events({
    type: "extension_ui_request",
    id: "blocked-editor",
    method: "editor",
    title: "Fixture",
    text: "",
  })
  await until(() => host.snapshot.dialogs.length === 1)
  const id = required(host.snapshot.dialogs[0]).id,
    child = rpc(),
    pid = required(child.childPid)
  await child.request("pause_stdin")
  const filling = child
    .request("fixture_echo", { value: "x".repeat(900_000) }, 5000)
    .catch(() => {})
  const before = performance.now()
  expect(await send("answer", { dialog: id, value: "\0".repeat(65536), cancelled: false })).toEqual(
    { failure: { _0: "unknownOutcome" } },
  )
  expect(performance.now() - before).toBeLessThan(2500)
  expect(await send("stop")).toEqual({ ok: {} })
  expect(() => process.kill(pid, 0)).toThrow()
  await filling
})

test("Stop forces confirmed cleanup when Pi no longer reads its control commands", async () => {
  await open()
  await create()
  const child = rpc(),
    pid = required(child.childPid)
  await child.request("pause_stdin")
  const filling = child
    .request("fixture_echo", { value: "x".repeat(900_000) }, 5000)
    .catch(() => {})
  const before = performance.now()
  expect(await send("stop")).toEqual({ ok: {} })
  expect(performance.now() - before).toBeLessThan(3000)
  expect(() => process.kill(pid, 0)).toThrow()
  expect(host.snapshot.phase).toBe("interrupted")
  await filling
})

test("receipt persistence failure after Pi acceptance never records a definitive rejection", async () => {
  await open()
  await create()
  const original = storage.writeJSON.bind(storage)
  let writes = 0
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "requests.json" && ++writes === 2)
      throw Object.assign(new Error("fixture disk failure"), { code: "EIO" })
    return original(name, value, maximum)
  })
  const id = randomUUID().toUpperCase()
  const input = { text: "/handled", delivery: "prompt" }
  expect(await send("prompt", input, { id })).toEqual({ failure: { _0: "unknownOutcome" } })
  expect(await send("prompt", input, { id })).toEqual({ failure: { _0: "unknownOutcome" } })
  expect(((await rpc().request("get_state")) as Record<string, unknown>).prompts).toBe(1)
  expect(host.snapshot.error).toBe("unknownOutcome")
  mocked.mockRestore()
})

test("malformed lifecycle cannot make active Pi idle or authorize Close", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  await events({ type: "agent_settled", aborted: "not-a-boolean" })
  await until(() => host.snapshot.error === "unknownOutcome")
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  expect(host.snapshot.error).toBe("unknownOutcome")
  expect(await send("stop")).toEqual({ ok: {} })
})

test("explicit prompt rejection restores idle without erasing uncertain outcomes", async () => {
  await open()
  await create()
  const child = rpc(),
    original = child.request.bind(child)
  const mocked = spyOn(child, "request").mockImplementation((command, ...args) =>
    command === "prompt"
      ? Promise.reject(new RPCError("providerAuthenticationRequired", "Rejected fixture request"))
      : original(command, ...args),
  )
  expect(await send("prompt", { text: "Rejected fixture", delivery: "prompt" })).toEqual({
    failure: { _0: "providerAuthenticationRequired" },
  })
  expect(host.snapshot.phase).toBe("idle")
  mocked.mockRestore()
  expect(await send("closeSession")).toEqual({ ok: {} })
})

test("unknown child exit stays latched until explicit Stop confirms process cleanup", async () => {
  await open()
  await create()
  const selected = required(host.snapshot.selected)
  await rpc()
    .request("fixture_crash")
    .catch(() => {})
  await until(() => host.snapshot.error === "unknownOutcome")
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  expect(host.snapshot.error).toBe("unknownOutcome")
  expect(await send("resumeSession", { id: selected })).toEqual({ failure: { _0: "busy" } })
  expect(host.snapshot.error).toBe("unknownOutcome")
  expect(await send("stop")).toEqual({ ok: {} })
  expect(host.snapshot.notices.some((value) => value.includes("unknown outcome"))).toBe(true)
  expect(await send("closeSession")).toEqual({ ok: {} })
  expect(await send("resumeSession", { id: selected })).toEqual({ ok: {} })
})

test("wire budgets account for escaped JSON and preserve a usable capacity recovery state", async () => {
  await open()
  host.snapshot.messages = Array.from({ length: 32 }, () => ({
    id: randomUUID().toUpperCase(),
    role: "user",
    text: "\t".repeat(65536),
    isError: false,
    streaming: false,
    truncated: false,
  }))
  const state = host.wireSnapshot()
  expect(state.hasOlderMessages).toBe(true)
  expect(Buffer.byteLength(JSON.stringify(state))).toBeLessThanOrEqual(2 * 1024 * 1024)
  expect(() =>
    packet({ reply: { id: randomUUID(), result: enumValue("snapshot", state) } }),
  ).not.toThrow()
  host.snapshot.notices = ["x".repeat(3 * 1024 * 1024)]
  const recovery = host.wireSnapshot()
  expect(recovery.error).toBe("capacity")
  expect(recovery.capabilities).toContain("stop")
  expect(() => packet(enumValue("state", recovery))).not.toThrow()
})

test("directory error rows map private faults to the Swift fault vocabulary", async () => {
  await open()
  const page = await host.directories.list()
  const directories = host.directories as unknown as { register(path: string): string }
  const original = directories.register.bind(directories)
  const mocked = spyOn(directories, "register").mockImplementation((path) =>
    path.endsWith("/project")
      ? (() => {
          throw new Fault("resourceLimit")
        })()
      : original(path),
  )
  const listed = await host.directories.list(page.id)
  expect(listed.items.find((item) => item.name === "project")?.fault).toBe("capacity")
  mocked.mockRestore()
})

test("extension commands remain available during work without allowing template commands", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const waiting = send("command", { name: "fixture-select", arguments: "" })
  await until(() => host.snapshot.dialogs.length === 1)
  expect(
    await send("answer", { dialog: "fixture-dialog", value: "Second", cancelled: false }),
  ).toEqual({ ok: {} })
  expect(await waiting).toEqual({ ok: {} })
  expect(host.snapshot.phase).toBe("working")
  expect(await send("stop")).toEqual({ ok: {} })
})

test("tool errors remain visible and model/thinking changes use confirmed state", async () => {
  await open()
  await create()
  expect(await send("model", { provider: "fixture", id: "other-model" })).toEqual({ ok: {} })
  expect(host.snapshot.model).toBe("fixture/other-model")
  expect(await send("thinking", { level: "high" })).toEqual({ ok: {} })
  expect(host.snapshot.thinking).toBe("high")
  expect(await send("thinking", { level: "invented" })).toEqual({
    failure: { _0: "invalidRequest" },
  })
  expect(host.snapshot.thinking).toBe("high")
  await events(
    {
      type: "tool_execution_start",
      toolCallId: "failed-tool",
      toolName: "read",
      args: { path: "missing" },
    },
    {
      type: "tool_execution_end",
      toolCallId: "failed-tool",
      toolName: "read",
      isError: true,
      result: { content: [{ type: "text", text: "File not found" }] },
    },
  )
  await until(() => host.snapshot.messages.some((message) => message.isError))
  expect(host.snapshot.messages).toContainEqual(
    expect.objectContaining({ isError: true, text: expect.stringContaining("File not found") }),
  )
})

test("an extension command can receive its answer while its RPC acceptance is pending", async () => {
  await open()
  await create()
  let accepted = false
  const command = send("command", { name: "fixture-select", arguments: "" }).then((result) => {
    accepted = true
    return result
  })
  await until(() => host.snapshot.dialogs.some((dialog) => dialog.id === "fixture-dialog"))
  expect(accepted).toBe(false)
  expect(await send("closeSession")).toEqual({ failure: { _0: "busy" } })
  expect(
    await send("answer", { dialog: "fixture-dialog", value: "First", cancelled: false }),
  ).toEqual({ ok: {} })
  expect(await command).toEqual({ ok: {} })
  expect(host.snapshot.dialogs).toEqual([])
  expect(host.snapshot.phase).toBe("idle")
  expect(await send("closeSession")).toEqual({ ok: {} })
})

test("Stop cancels a pending extension dialog and releases the waiting command", async () => {
  await open()
  await create()
  let accepted = false
  const command = send("command", { name: "fixture-select", arguments: "" }).then((result) => {
    accepted = true
    return result
  })
  await until(() => host.snapshot.dialogs.some((dialog) => dialog.id === "fixture-dialog"))
  expect(accepted).toBe(false)
  expect(await send("stop")).toEqual({ ok: {} })
  expect(await command).toEqual({ ok: {} })
  expect(host.snapshot.phase).toBe("idle")
  expect(host.snapshot.dialogs).toEqual([])
  expect(host.snapshot.pendingMessages).toBe(0)
  expect(
    await send("answer", { dialog: "fixture-dialog", value: "First", cancelled: false }),
  ).toEqual({ failure: { _0: "expired" } })
  expect(await send("closeSession")).toEqual({ ok: {} })
})

test("review regression: oversized select options are cancelled, not changed", async () => {
  await open()
  await create()
  const answers = spyOn(rpc(), "answer")
  try {
    const prefix = "é".repeat(256)
    await events({
      type: "extension_ui_request",
      id: "oversized-select",
      method: "select",
      title: "Fixture",
      options: [`${prefix}A`, `${prefix}B`],
    })
    await until(() =>
      answers.mock.calls.some(
        ([answer]) => answer.id === "oversized-select" && answer.cancelled === true,
      ),
    )
    expect(host.wireSnapshot().dialogs).toEqual([])
    expect(
      host.snapshot.notices.some((notice) => notice.includes("selection is unavailable")),
    ).toBe(true)
  } finally {
    answers.mockRestore()
  }
})

function fillReceiptTable(): Record<string, { digest: string; done: boolean; fault?: string }> {
  const receipts = (
    host as unknown as {
      receipts: Record<string, { digest: string; done: boolean; fault?: string }>
    }
  ).receipts
  for (let index = Object.keys(receipts).length; index < 10_000; index++) {
    receipts[`capacity-fixture-${index}`] = {
      digest: "0".repeat(64),
      done: true,
      ...(index % 2 ? { fault: "invalidRequest" } : {}),
    }
  }
  return receipts
}

test("review regression: full receipt storage cannot block Stop", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const child = rpc(),
    pid = required(child.childPid),
    receipts = fillReceiptTable()
  expect(((await child.request("get_state")) as Record<string, unknown>).isStreaming).toBe(true)
  expect(await send("stop")).toEqual({ ok: {} })
  expect(() => process.kill(pid, 0)).toThrow()
  expect(Object.keys(receipts)).toHaveLength(10_000)
  expect(host.snapshot.error).toBe("capacity")
  expect(host.snapshot.notices.some((notice) => notice.includes("Restart the host"))).toBe(true)
})

test("capacity Stop keeps old receipts and remains bounded across repeated requests", async () => {
  await open()
  await create()
  const prompt = request("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })
  expect(await host.handle(prompt, device, () => true)).toEqual({ ok: {} })
  const child = rpc(),
    calls = spyOn(child, "request"),
    receipts = fillReceiptTable()
  const keys = Object.keys(receipts),
    journal = spyOn(storage, "writeJSON")
  try {
    const stop = request("stop")
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
    for (let index = 0; index < 32; index++) expect(await send("stop")).toEqual({ ok: {} })
    expect(Object.keys(receipts)).toEqual(keys)
    expect(journal.mock.calls.filter(([name]) => name === "requests.json")).toHaveLength(0)
    expect(calls.mock.calls.filter(([command]) => command === "abort")).toHaveLength(1)
    expect(await host.handle(prompt, device, () => true)).toEqual({ ok: {} })
    expect(await send("prompt", { text: "Do not start new work", delivery: "prompt" })).toEqual({
      failure: { _0: "capacity" },
    })
    expect(await send("createSession", { directory: (await host.directories.list()).id })).toEqual({
      failure: { _0: "capacity" },
    })
    expect(rpc()).toBeUndefined()
    expect(Object.keys(receipts)).toEqual(keys)
  } finally {
    calls.mockRestore()
    journal.mockRestore()
  }
})

test("capacity Stop keeps authorization, epoch and session checks", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const child = rpc(),
    pid = required(child.childPid)
  fillReceiptTable()
  expect(await host.handle(request("stop"), device, () => false)).toEqual({
    failure: { _0: "unauthorized" },
  })
  expect(await send("stop", {}, { epoch: randomUUID().toUpperCase() })).toEqual({
    failure: { _0: "unknownOutcome" },
  })
  expect(await send("stop", {}, { session: randomUUID().toUpperCase() })).toEqual({
    failure: { _0: "conflict" },
  })
  expect(((await child.request("get_state")) as Record<string, unknown>).isStreaming).toBe(true)
  expect(await send("stop")).toEqual({ ok: {} })
  expect(() => process.kill(pid, 0)).toThrow()
})

test("capacity Stop can stop Pi while receipt and catalog storage are unavailable", async () => {
  await open()
  await create()
  const pid = required(rpc().childPid),
    receipts = fillReceiptTable()
  const original = storage.writeJSON.bind(storage)
  const journal = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "requests.json" || name === "sessions.json")
      throw Object.assign(new Error("fixture full disk"), { code: "ENOSPC" })
    return original(name, value, maximum)
  })
  try {
    expect(await send("stop")).toEqual({ ok: {} })
    expect(() => process.kill(pid, 0)).toThrow()
    expect(Object.keys(receipts)).toHaveLength(10_000)
    expect(journal.mock.calls.filter(([name]) => name === "requests.json")).toHaveLength(0)
    expect(
      host.snapshot.notices.some((notice) => notice.includes("Private session storage failed")),
    ).toBe(true)
  } finally {
    journal.mockRestore()
  }
})

test("capacity Stop reports unconfirmed termination and releases interrupt admission", async () => {
  await open()
  await create()
  const child = rpc(),
    pid = required(child.childPid),
    receipts = fillReceiptTable()
  const shutdown = spyOn(child, "shutdown").mockRejectedValue(
    new RPCError("unknownOutcome", "Fixture exit not confirmed"),
  )
  try {
    expect(await send("stop")).toEqual({ failure: { _0: "unknownOutcome" } })
    expect(host.snapshot.error).toBe("unknownOutcome")
    expect(process.kill(pid, 0)).toBe(true)
    expect(Object.keys(receipts)).toHaveLength(10_000)
  } finally {
    shutdown.mockRestore()
  }
  expect(await send("stop")).toEqual({ ok: {} })
  expect(() => process.kill(pid, 0)).toThrow()
})

test("restart resets receipt capacity without activating or replaying work", async () => {
  await open()
  await create()
  const id = required(host.snapshot.selected),
    epoch = host.snapshot.epoch
  fillReceiptTable()
  expect(await send("stop")).toEqual({ ok: {} })
  await host.shutdown()
  await open()
  expect(host.snapshot.epoch).not.toBe(epoch)
  expect(host.snapshot.selected).toBeUndefined()
  expect(rpc()).toBeUndefined()
  expect(await send("resumeSession", { id })).toEqual({ ok: {} })
  expect(host.snapshot.selected).toBe(id)
})

test("capacity Stop fences a prompt still waiting for durable catalog acceptance", async () => {
  await open()
  await create()
  const child = rpc(),
    calls = spyOn(child, "request"),
    original = storage.writeJSON.bind(storage)
  let reached = false,
    release = () => {}
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "sessions.json" && !reached) {
      reached = true
      await gate
    }
    return original(name, value, maximum)
  })
  const waiting = send("prompt", { text: "Must not start after capacity Stop", delivery: "prompt" })
  try {
    await until(() => reached)
    fillReceiptTable()
    const stopped = send("stop")
    await until(() => (host as unknown as { stopRevision: number }).stopRevision > 0)
    release()
    expect(await stopped).toEqual({ ok: {} })
    expect(await waiting).toEqual({ failure: { _0: "cancelled" } })
    expect(calls.mock.calls.filter(([command]) => command === "prompt")).toHaveLength(0)
    expect(rpc()).toBeUndefined()
  } finally {
    release()
    mocked.mockRestore()
    calls.mockRestore()
  }
})

test("review regression: Stop still stops Pi when its journal cannot be written", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const child = rpc(),
    pid = required(child.childPid)
  expect(((await child.request("get_state")) as Record<string, unknown>).isStreaming).toBe(true)
  const original = storage.writeJSON.bind(storage)
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "requests.json")
      throw Object.assign(new Error("fixture full disk"), { code: "ENOSPC" })
    return original(name, value, maximum)
  })
  try {
    const stop = request("stop")
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
    expect(() => process.kill(pid, 0)).toThrow()
    expect(host.snapshot.error).toBe("storageFailure")
    expect(host.snapshot.notices.some((notice) => notice.includes("Stop receipt"))).toBe(true)
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
  } finally {
    mocked.mockRestore()
  }
})

test("review regression: activating another session clears extension editor offers", async () => {
  await open()
  await create()
  await events({
    type: "extension_ui_request",
    id: "editor-offer-A",
    method: "set_editor_text",
    text: "Instructions for project A",
  })
  await until(() => host.snapshot.draftID !== undefined)
  expect(host.wireSnapshot().draft).toBe("Instructions for project A")
  const page = await host.directories.list()
  expect(await send("createSession", { directory: page.id })).toEqual({ ok: {} })
  expect(host.wireSnapshot().draft).toBeUndefined()
  expect(host.wireSnapshot().draftID).toBeUndefined()
})

for (const [label, options] of [
  ["control text", ["\u001b[31mRed", "Blue"]],
  ["duplicate values", ["same", "same"]],
  ["equivalent Swift identifiers", ["é", "e\u0301"]],
  ["too many options", Array.from({ length: 101 }, (_, index) => String(index))],
  ["non-string option", ["safe", 42]],
] as const) {
  test(`unsafe select dialog is unavailable: ${label}`, async () => {
    await open()
    await create()
    const answers = spyOn(rpc(), "answer")
    try {
      await events({ type: "extension_ui_request", id: "unsafe-select", method: "select", options })
      await until(() =>
        answers.mock.calls.some(
          ([answer]) => answer.id === "unsafe-select" && answer.cancelled === true,
        ),
      )
      expect(host.wireSnapshot().dialogs).toEqual([])
    } finally {
      answers.mockRestore()
    }
  })
}

test("safe select options reach Pi unchanged and unoffered answers do not consume the dialog", async () => {
  await open()
  await create()
  const answers = spyOn(rpc(), "answer")
  try {
    const options = ["é".repeat(256), "Second"]
    await events({ type: "extension_ui_request", id: "exact-select", method: "select", options })
    await until(() => host.snapshot.dialogs.some((dialog) => dialog.id === "exact-select"))
    expect(host.wireSnapshot().dialogs[0]?.options).toEqual(options)
    expect(
      await send("answer", { dialog: "exact-select", value: "not offered", cancelled: false }),
    ).toEqual({ failure: { _0: "invalidRequest" } })
    expect(host.snapshot.dialogs).toHaveLength(1)
    expect(answers).not.toHaveBeenCalled()
    expect(
      await send("answer", { dialog: "exact-select", value: options[0], cancelled: false }),
    ).toEqual({ ok: {} })
    expect(answers).toHaveBeenCalledWith({
      id: "exact-select",
      value: options[0],
      confirmed: undefined,
      cancelled: false,
    })
  } finally {
    answers.mockRestore()
  }
})

for (const code of ["EACCES", "ENOSPC"] as const) {
  test(`Stop bypasses failed receipt admission, not authorization: ${code}`, async () => {
    await open()
    await create()
    expect(
      await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" }),
    ).toEqual({ ok: {} })
    const pid = required(rpc().childPid),
      original = storage.writeJSON.bind(storage)
    const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
      if (name === "requests.json" || name === "sessions.json")
        throw Object.assign(new Error("fixture unavailable disk"), { code })
      return original(name, value, maximum)
    })
    try {
      expect(await host.handle(request("stop"), device, () => false)).toEqual({
        failure: { _0: "unauthorized" },
      })
      expect(await send("stop", {}, { session: randomUUID().toUpperCase() })).toEqual({
        failure: { _0: "conflict" },
      })
      expect(process.kill(pid, 0)).toBe(true)
      expect(await send("stop")).toEqual({ ok: {} })
      expect(() => process.kill(pid, 0)).toThrow()
      expect(host.wireSnapshot().error).toBe("storageFailure")
      expect(host.snapshot.phase).toBe("interrupted")
    } finally {
      mocked.mockRestore()
    }
  })
}

test("a failed final Stop receipt does not erase confirmed idle or repeat the abort", async () => {
  await open()
  await create()
  expect(await send("prompt", { text: "CLI fixture: wait for Stop", delivery: "prompt" })).toEqual({
    ok: {},
  })
  const child = rpc(),
    calls = spyOn(child, "request"),
    original = storage.writeJSON.bind(storage)
  let writes = 0
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "requests.json" && ++writes >= 2)
      throw Object.assign(new Error("fixture full disk"), { code: "ENOSPC" })
    return original(name, value, maximum)
  })
  try {
    const stop = request("stop")
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
    expect(host.snapshot.phase).toBe("idle")
    expect(host.snapshot.error).toBe("storageFailure")
    expect(await host.handle(stop, device, () => true)).toEqual({ ok: {} })
    expect(calls.mock.calls.filter(([command]) => command === "abort")).toHaveLength(1)
    expect(((await child.request("get_state")) as Record<string, unknown>).isStreaming).toBe(false)
  } finally {
    mocked.mockRestore()
    calls.mockRestore()
  }
})

test("failed Stop receipt storage cannot turn unconfirmed process cleanup into success", async () => {
  await open()
  await create()
  const child = rpc(),
    original = storage.writeJSON.bind(storage)
  const shutdown = spyOn(child, "shutdown").mockRejectedValue(
    new RPCError("unknownOutcome", "Fixture termination not confirmed"),
  )
  const mocked = spyOn(storage, "writeJSON").mockImplementation(async (name, value, maximum) => {
    if (name === "requests.json")
      throw Object.assign(new Error("fixture full disk"), { code: "ENOSPC" })
    return original(name, value, maximum)
  })
  try {
    expect(await send("stop")).toEqual({ failure: { _0: "unknownOutcome" } })
    expect(host.snapshot.error).toBe("unknownOutcome")
    expect(process.kill(required(child.childPid), 0)).toBe(true)
  } finally {
    mocked.mockRestore()
    shutdown.mockRestore()
  }
})

for (const action of ["resumeSession", "closeSession"] as const) {
  test(`${action} clears session-scoped editor offers in snapshots and replay`, async () => {
    await open()
    await create()
    const first = required(host.snapshot.selected)
    const page = await host.directories.list()
    expect(await send("createSession", { directory: page.id })).toEqual({ ok: {} })
    await events({
      type: "extension_ui_request",
      id: "editor-B",
      method: "set_editor_text",
      text: "Project B only",
    })
    await until(() => host.snapshot.draftID !== undefined)
    const after = host.snapshot.sequence
    expect(await send(action, action === "resumeSession" ? { id: first } : {})).toEqual({ ok: {} })
    const snapshot = (await send("snapshot")) as {
      snapshot: { _0: { draft?: string; draftID?: string } }
    }
    expect(snapshot.snapshot._0.draft).toBeUndefined()
    expect(snapshot.snapshot._0.draftID).toBeUndefined()
    const replay = (await send("synchronize", { epoch: host.snapshot.epoch, after })) as {
      synchronized: { _0: { events: { selected?: string; draft?: string; draftID?: string }[] } }
    }
    const current = replay.synchronized._0.events.filter(
      (state) => state.selected === host.snapshot.selected,
    )
    expect(current.length).toBeGreaterThan(0)
    for (const state of current) {
      expect(state.draft).toBeUndefined()
      expect(state.draftID).toBeUndefined()
    }
    if (action === "closeSession") expect(host.snapshot.selected).toBeUndefined()
    else expect(host.snapshot.selected).toBe(first)
  })
}

test("dialogs expire, reject duplicate answers and reject stale session context", async () => {
  await open()
  await create()
  const id = required(host.snapshot.selected)
  await events({
    type: "extension_ui_request",
    id: "expiring",
    method: "confirm",
    title: "Confirm",
    timeout: 50,
  })
  await until(() => host.snapshot.dialogs.length === 1)
  await until(() => host.snapshot.dialogs.length === 0)
  expect(await send("answer", { dialog: "expiring", confirmed: true, cancelled: false })).toEqual({
    failure: { _0: "expired" },
  })
  await events({
    type: "extension_ui_request",
    id: "answer-once",
    method: "input",
    title: "Input",
    timeout: 1000,
  })
  await until(() => host.snapshot.dialogs.some((dialog) => dialog.id === "answer-once"))
  expect(
    await send(
      "answer",
      { dialog: "answer-once", value: "yes", cancelled: false },
      { session: randomUUID().toUpperCase() },
    ),
  ).toEqual({ failure: { _0: "conflict" } })
  expect(host.snapshot.dialogs).toHaveLength(1)
  expect(await send("answer", { dialog: "answer-once", value: "yes", cancelled: false })).toEqual({
    ok: {},
  })
  expect(await send("answer", { dialog: "answer-once", value: "again", cancelled: false })).toEqual(
    { failure: { _0: "expired" } },
  )
  expect(await send("closeSession")).toEqual({ ok: {} })
  expect(await send("answer", { dialog: "answer-once", cancelled: true }, { session: id })).toEqual(
    { failure: { _0: "conflict" } },
  )
})
