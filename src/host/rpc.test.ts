import { afterEach, describe, expect, test } from "bun:test"
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { PiRPC, RPC_LIMITS, RPCError } from "./rpc.ts"

const entry = resolve(import.meta.dir, "../fixtures/fake-pi.ts")
const children: PiRPC[] = []
async function start(
  mode = "normal",
  callbacks: {
    onEvent?: (event: Record<string, unknown>) => void
    onFault?: (error: Error) => void
    onExit?: () => void
  } = {},
): Promise<PiRPC> {
  const rpc = new PiRPC({
    entry,
    cwd: process.cwd(),
    args: [],
    env: { RPC_FIXTURE_MODE: mode },
    onEvent: callbacks.onEvent ?? (() => {}),
    ...callbacks,
  })
  children.push(rpc)
  await rpc.start()
  return rpc
}
afterEach(async () => {
  await Promise.all(children.splice(0).map((child) => child.shutdown()))
})
async function until(check: () => boolean, timeout = 2500): Promise<void> {
  const deadline = Date.now() + timeout
  while (!check()) {
    if (Date.now() > deadline) throw new Error("Fixture condition timed out")
    await Bun.sleep(5)
  }
}
function isAlive(pid: number | undefined): boolean {
  if (!pid) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

describe("Pi RPC subprocess", () => {
  test("handshakes on Bun in the selected directory and returns data including null", async () => {
    const rpc = await start()
    const state = (await rpc.request("get_state")) as Record<string, unknown>
    expect(state.isStreaming).toBe(false)
    expect(state.cwd).toBe(process.cwd())
    expect(state.execPath).toBe(process.execPath)
    expect(rpc.childPid).toBeNumber()
    expect(await rpc.request("fixture_null")).toBeNull()
    expect(await rpc.request("set_thinking_level", { level: "high" })).toBeUndefined()
  })

  test("rejects requests before readiness and does not spawn for relative entry", async () => {
    const rpc = new PiRPC({ entry: "relative.js", cwd: process.cwd(), args: [], onEvent: () => {} })
    await expect(rpc.request("prompt")).rejects.toMatchObject({ code: "unavailable" })
    await expect(rpc.start()).rejects.toMatchObject({ code: "invalidRequest" })
    expect(rpc.childPid).toBeUndefined()
    await rpc.shutdown()
  })

  test("correlates concurrent commands and prevents field overrides", async () => {
    const rpc = await start()
    const values = Array.from(
      { length: 32 },
      (_, index) => `${index} ' " ; $(private) ${"x".repeat(3000)}`,
    )
    const results = await Promise.all(
      values.map((value) => rpc.request("fixture_echo", { value, type: "prompt", id: "override" })),
    )
    expect(results).toEqual(values.map((value) => ({ value })))
  })

  test("splits only LF, accepts CRLF, and preserves split UTF-8 and Unicode separators", async () => {
    const events: Record<string, unknown>[] = []
    const rpc = await start("normal", { onEvent: (event) => events.push(event) })
    await rpc.request("fixture_split")
    await until(() => events.length === 1)
    expect(events[0]).toEqual({ type: "fixture_text", text: "é🙂\u2028\u2029" })
  })

  test("extension answers have no pending command response", async () => {
    const events: Record<string, unknown>[] = []
    const rpc = await start("normal", { onEvent: (event) => events.push(event) })
    await rpc.answer({ id: "dialog-1", confirmed: false, type: "prompt" })
    await until(() => events.length === 1)
    expect(events[0]).toEqual({
      type: "fixture_answer",
      answer: { type: "extension_ui_response", id: "dialog-1", confirmed: false },
    })
    await expect(rpc.answer({})).rejects.toBeInstanceOf(RPCError)
  })

  test("prompt acknowledgement is not completion, and agent_end precedes settlement", async () => {
    const events: Record<string, unknown>[] = []
    const rpc = await start("normal", { onEvent: (event) => events.push(event) })
    expect(await rpc.request("prompt", { message: "hello" })).toEqual({ disposition: "started" })
    expect(events.some((event) => event.type === "agent_settled")).toBe(false)
    await until(() => events.some((event) => event.type === "agent_settled"))
    expect(events.findIndex((event) => event.type === "agent_end")).toBeLessThan(
      events.findIndex((event) => event.type === "agent_settled"),
    )
    const previous = events.length
    expect(await rpc.request("prompt", { message: "/handled" })).toEqual({ disposition: "handled" })
    await Bun.sleep(60)
    expect(events.length).toBe(previous)
  })

  test("acceptance fixture writes in its project, persists history, resumes explicitly, and waits for Stop", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "pi-rpc-acceptance-")))
    const events: Record<string, unknown>[] = []
    const rpc = new PiRPC({
      entry,
      cwd: root,
      args: ["--session-dir", join(root, "sessions"), "--session-id", "fixture-acceptance"],
      onEvent: (event) => events.push(event),
    })
    children.push(rpc)
    try {
      await rpc.start()
      await rpc.request("prompt", {
        message: "CLI fixture: write acceptance.txt with CLI acceptance\n",
      })
      await until(() => events.some((event) => event.type === "agent_settled"))
      expect(await readFile(join(root, "acceptance.txt"), "utf8")).toBe("CLI acceptance\n")
      expect(events.some((event) => event.type === "tool_execution_end")).toBe(true)
      const state = (await rpc.request("get_state")) as Record<string, unknown>
      const file = state.sessionFile as string
      expect(JSON.parse((await readFile(file, "utf8")).split("\n")[0] ?? "")).toMatchObject({
        type: "session",
        version: 3,
        id: "fixture-acceptance",
        cwd: root,
      })
      await rpc.shutdown()
      const resumed = new PiRPC({ entry, cwd: root, args: ["--session", file], onEvent: () => {} })
      children.push(resumed)
      await resumed.start()
      expect(
        ((await resumed.request("get_messages")) as { messages: unknown[] }).messages.length,
      ).toBeGreaterThanOrEqual(3)
      await resumed.request("prompt", { message: "CLI fixture: wait for Stop" })
      await Bun.sleep(60)
      expect(((await resumed.request("get_state")) as Record<string, unknown>).isStreaming).toBe(
        true,
      )
      await resumed.request("steer", { message: "steering" })
      await resumed.request("follow_up", { message: "follow-up" })
      expect(await resumed.request("clear_queue")).toEqual({
        steering: ["steering"],
        followUp: ["follow-up"],
      })
      await resumed.request("abort")
      expect(((await resumed.request("get_state")) as Record<string, unknown>).isStreaming).toBe(
        false,
      )
      await resumed.shutdown()
    } finally {
      await rpc.shutdown()
      await rm(root, { recursive: true, force: true })
    }
  })

  test("drains large private stderr without retaining it in results", async () => {
    const rpc = await start()
    expect(await rpc.request("fixture_stderr")).toBeUndefined()
    expect(JSON.stringify(rpc)).not.toContain("private-provider-secret")
  })

  test("sanitizes errors and classifies provider authentication failure", async () => {
    const rpc = await start()
    for (const [error, code] of [
      ["private prompt rejected", "invalidRequest"],
      ["Missing API key: PRIVATE_SECRET", "providerAuthenticationRequired"],
    ]) {
      try {
        await rpc.request("fixture_error", { error })
        throw new Error("Expected rejection")
      } catch (fault) {
        expect(fault).toBeInstanceOf(RPCError)
        expect((fault as RPCError).code).toBe(code)
        expect((fault as Error).message).not.toContain("PRIVATE_SECRET")
        expect((fault as Error).message).not.toContain("private prompt")
      }
    }
  })

  test("deadline and cancellation have unknown outcomes with no replay", async () => {
    const events: Record<string, unknown>[] = []
    const rpc = await start("normal", { onEvent: (event) => events.push(event) })
    await expect(rpc.request("fixture_delayed", {}, 10)).rejects.toMatchObject({
      code: "unknownOutcome",
    })
    const controller = new AbortController()
    const request = rpc.request("fixture_delayed", {}, 5000, controller.signal)
    controller.abort()
    await expect(request).rejects.toMatchObject({ code: "unknownOutcome" })
    await Bun.sleep(120)
    expect(events).toEqual([])
    expect(await rpc.request("fixture_echo", { value: "still ready" })).toEqual({
      value: "still ready",
    })
    await rpc.request("prompt", { message: "/handled" })
    expect(((await rpc.request("get_state")) as Record<string, unknown>).prompts).toBe(1)
  })

  test("rejects oversize, unserializable and invalid-deadline commands before dispatch", async () => {
    const rpc = await start()
    await expect(
      rpc.request("prompt", { message: "x".repeat(RPC_LIMITS.commandBytes) }),
    ).rejects.toMatchObject({ code: "invalidRequest" })
    await expect(rpc.request("prompt", { message: 1n })).rejects.toMatchObject({
      code: "invalidRequest",
    })
    await expect(rpc.request("prompt", {}, Infinity)).rejects.toMatchObject({
      code: "invalidRequest",
    })
    expect(((await rpc.request("get_state")) as Record<string, unknown>).prompts).toBe(0)
  })

  test("bounds pending command count", async () => {
    const rpc = await start()
    const pending = Array.from({ length: RPC_LIMITS.pendingCount + 8 }, () =>
      rpc.request("fixture_no_response", {}, 100),
    )
    const results = await Promise.allSettled(pending)
    expect(
      results.some(
        (result) => result.status === "rejected" && result.reason.code === "invalidRequest",
      ),
    ).toBe(true)
    expect(results.every((result) => result.status === "rejected")).toBe(true)
  })

  test("blocked stdin has byte/count admission and cannot block shutdown", async () => {
    const rpc = await start("blocked-stdin")
    const requests = Array.from({ length: 12 }, () =>
      rpc.request("fixture_echo", { value: "x".repeat(700_000) }, 300),
    )
    const settled = Promise.allSettled(requests)
    const before = Date.now()
    await rpc.shutdown()
    expect(Date.now() - before).toBeLessThan(2500)
    expect(isAlive(rpc.childPid)).toBe(false)
    const results = await settled
    expect(
      results.some(
        (result) => result.status === "rejected" && result.reason.code === "invalidRequest",
      ),
    ).toBe(true)
  })

  test("extension answers have a write deadline and cannot retain a blocked child", async () => {
    const rpc = await start("blocked-stdin")
    const filling = rpc
      .request("fixture_echo", { value: "x".repeat(900_000) }, 5000)
      .catch(() => {})
    const before = Date.now()
    await expect(
      rpc.answer({ id: "blocked-dialog", value: "\0".repeat(65536) }),
    ).rejects.toMatchObject({ code: "unknownOutcome" })
    expect(Date.now() - before).toBeLessThan(2500)
    await rpc.shutdown()
    expect(isAlive(rpc.childPid)).toBe(false)
    await filling
  })

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    test(`managed children keep the default ${signal} disposition`, async () => {
      const rpc = await start()
      process.kill(rpc.childPid as number, signal)
      await until(() => !isAlive(rpc.childPid))
      expect(isAlive(rpc.childPid)).toBe(false)
    })
  }

  test("child crash rejects pending requests with an explicit unknown outcome", async () => {
    let exited = false
    const rpc = await start("normal", {
      onExit: () => {
        exited = true
      },
    })
    await expect(rpc.request("fixture_crash")).rejects.toMatchObject({ code: "unknownOutcome" })
    await until(() => exited)
    expect(isAlive(rpc.childPid)).toBe(false)
  })

  test("startup exit and invalid handshake cannot claim readiness", async () => {
    await expect(start("startup-crash")).rejects.toBeInstanceOf(RPCError)
    await expect(start("malformed-handshake")).rejects.toBeInstanceOf(RPCError)
    for (const child of children) expect(isAlive(child.childPid)).toBe(false)
  })

  test("startup deadline cleans up its managed child", async () => {
    await expect(start("startup-hang")).rejects.toMatchObject({ code: "unknownOutcome" })
    for (const child of children) expect(isAlive(child.childPid)).toBe(false)
  }, 15_000)

  test("shutdown is idempotent, closes stdin first, and confirms forced exit", async () => {
    const normal = await start()
    await normal.shutdown()
    await normal.shutdown()
    expect(isAlive(normal.childPid)).toBe(false)
    const stubborn = await start("ignore-shutdown")
    const before = Date.now()
    await stubborn.shutdown()
    expect(Date.now() - before).toBeGreaterThanOrEqual(
      RPC_LIMITS.gracefulMs + RPC_LIMITS.termMs - 20,
    )
    expect(Date.now() - before).toBeLessThan(2500)
    expect(isAlive(stubborn.childPid)).toBe(false)
  })

  test.each([
    ["malformed JSON", "fixture_raw", { raw: "not-json\n" }],
    ["non-object JSON", "fixture_raw", { raw: "[]\n" }],
    ["blank records", "fixture_raw", { raw: "\n" }],
    ["missing type", "fixture_raw", { raw: "{}\n" }],
    ["invalid UTF-8", "fixture_invalid_utf8", {}],
    ["oversize stdout", "fixture_oversize", {}],
    ["unterminated stdout", "fixture_unterminated", {}],
    ["wrong response command", "fixture_mismatch", {}],
    [
      "uncorrelated response",
      "fixture_raw",
      { raw: '{"type":"response","command":"get_state","success":true}\n' },
    ],
    ["event delivery overflow", "fixture_flood", {}],
  ])("%s stops the managed child and reports a sanitized fault", async (_name, command, fields) => {
    const faults: Error[] = []
    const rpc = await start("normal", { onFault: (error) => faults.push(error) })
    await rpc.request(command as string, fields as Record<string, unknown>).catch(() => {})
    await until(() => faults.length > 0)
    await rpc.shutdown()
    expect(isAlive(rpc.childPid)).toBe(false)
    expect(faults[0]).toBeInstanceOf(RPCError)
    expect(faults[0]?.message).not.toContain("not-json")
  })

  test("throwing event callbacks do not prevent cleanup", async () => {
    let fault = false
    const rpc = await start("normal", {
      onEvent: () => {
        throw new Error("private")
      },
      onFault: () => {
        fault = true
        throw new Error("also private")
      },
    })
    await rpc.request("fixture_events", { events: [{ type: "agent_start" }] }).catch(() => {})
    await until(() => fault)
    await rpc.shutdown()
    expect(isAlive(rpc.childPid)).toBe(false)
  })
})
