// Provider-free RPC subprocess fixture. This file is never part of the published CLI.
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

if (process.argv.includes("--version")) {
  await Bun.write(Bun.stdout, "1.3.0\n")
  process.exit(0)
}
if (process.env.RPC_FIXTURE_PID_FILE)
  await writeFile(process.env.RPC_FIXTURE_PID_FILE, String(process.pid), { mode: 0o600 })
const mode = process.env.RPC_FIXTURE_MODE ?? "normal"
if (mode === "startup-crash") process.exit(7)
if (mode === "ignore-shutdown") process.on("SIGTERM", () => {})
const keepAlive = setInterval(() => {}, 1000)
const args = process.argv.slice(2)
const argument = (name: string) => args[args.indexOf(name) + 1]
let sessionId = args.includes("--session-id") ? argument("--session-id") : "fixture-session"
const sessionDirectory = args.includes("--session-dir") ? argument("--session-dir") : undefined
const sessionFile = args.includes("--session")
  ? argument("--session")
  : sessionDirectory
    ? join(sessionDirectory, `fixture_${sessionId}.jsonl`)
    : undefined
let streaming = false
let prompts = 0
let pendingDialogCommand: Record<string, unknown> | undefined
let pendingDialogID = "fixture-dialog"
let pendingDialogCount = 0
let model = { id: "fixture-model", provider: "fixture", name: "Fixture model", reasoning: true }
let thinkingLevel = "medium"
const messages: Record<string, unknown>[] = []
let leaf: string | null = null
if (sessionFile) {
  try {
    const lines = (await readFile(sessionFile, "utf8")).trim().split("\n")
    sessionId = JSON.parse(lines[0] ?? "{}").id
    for (const line of lines.slice(1)) {
      const entry = JSON.parse(line)
      if (entry.type === "message") messages.push(entry.message)
      leaf = entry.id
    }
  } catch {
    if (sessionDirectory) await mkdir(sessionDirectory, { recursive: true })
    await writeFile(
      sessionFile,
      `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: process.cwd(), timestamp: new Date().toISOString() })}\n`,
    )
  }
}
async function saveMessage(message: Record<string, unknown>): Promise<void> {
  messages.push(message)
  if (sessionFile) {
    const id = crypto.randomUUID()
    await appendFile(
      sessionFile,
      `${JSON.stringify({ type: "message", id, parentId: leaf, timestamp: new Date().toISOString(), message })}\n`,
    )
    leaf = id
  }
}
let steering: string[] = []
let followUp: string[] = []

function write(bytes: Uint8Array | string, stderr = false): Promise<void> {
  return new Promise((resolve, reject) => {
    ;(stderr ? process.stderr : process.stdout).write(bytes, (error) =>
      error ? reject(error) : resolve(),
    )
  })
}
async function emit(record: Record<string, unknown>): Promise<void> {
  await write(`${JSON.stringify(record)}\n`)
}
async function response(command: Record<string, unknown>, data?: unknown): Promise<void> {
  await emit({ type: "response", id: command.id, command: command.type, success: true, data })
}
async function handle(command: Record<string, unknown>): Promise<void> {
  switch (command.type) {
    case "get_state":
      if (mode === "startup-hang") return
      if (mode === "malformed-handshake") {
        await response(command, null)
        return
      }
      await response(command, {
        isStreaming: streaming,
        isCompacting: false,
        sessionFile,
        sessionId,
        model,
        thinkingLevel,
        pendingMessageCount: steering.length + followUp.length,
        prompts,
        cwd: process.cwd(),
        execPath: process.execPath,
      })
      if (mode === "blocked-stdin") await new Promise(() => {})
      return
    case "get_messages":
      await response(command, { messages })
      return
    case "get_commands":
      await response(command, {
        commands: [
          { name: "fixture-select", description: "Fixture selection", source: "extension" },
          {
            name: "fixture-select-twice",
            description: "Sequential fixture selections",
            source: "extension",
          },
        ],
      })
      return
    case "pause_stdin":
      await response(command)
      await new Promise(() => {})
      return
    case "get_available_models":
      await response(command, { models: [model] })
      return
    case "get_available_thinking_levels":
      await response(command, { levels: ["off", "low", "medium", "high"] })
      return
    case "set_model":
      model = { ...model, provider: String(command.provider), id: String(command.modelId) }
      await response(command, model)
      return
    case "set_thinking_level":
      thinkingLevel = String(command.level)
      await response(command)
      return
    case "steer":
      if (command.message === "CLI fixture: delayed preflight") await Bun.sleep(200)
      steering.push(String(command.message))
      await response(command, { disposition: "queued" })
      return
    case "follow_up":
      if (command.message === "CLI fixture: delayed preflight") await Bun.sleep(200)
      followUp.push(String(command.message))
      await response(command, { disposition: "queued" })
      return
    case "clear_queue":
      await response(command, { steering, followUp })
      steering = []
      followUp = []
      return
    case "abort":
      streaming = false
      await emit({ type: "agent_settled", aborted: true })
      await response(command)
      return
    case "prompt": {
      if (command.message === "/fixture-select" || command.message === "/fixture-select-twice") {
        pendingDialogCommand = command
        pendingDialogID = "fixture-dialog"
        pendingDialogCount = command.message === "/fixture-select-twice" ? 2 : 1
        await emit({
          type: "extension_ui_request",
          id: "fixture-dialog",
          method: "select",
          title: "Fixture selection",
          options: ["First", "Second"],
        })
        return
      }
      prompts++
      if (command.message === "/handled") {
        await response(command, { disposition: "handled" })
        return
      }
      if (command.message === "CLI fixture: delayed preflight") await Bun.sleep(200)
      streaming = true
      await response(command, { disposition: "started" })
      await emit({ type: "agent_start" })
      const user = { role: "user", content: String(command.message), timestamp: Date.now() }
      await saveMessage(user)
      await emit({ type: "message_start", message: user })
      await emit({ type: "message_end", message: user })
      if (command.message === "CLI fixture: wait for Stop") return
      if (command.message === "CLI fixture: write acceptance.txt with CLI acceptance\n") {
        await emit({
          type: "tool_execution_start",
          toolCallId: "acceptance-write",
          toolName: "write",
          args: { path: "acceptance.txt", content: "CLI acceptance\n" },
        })
        await writeFile(join(process.cwd(), "acceptance.txt"), "CLI acceptance\n")
        const result = { content: [{ type: "text", text: "Wrote acceptance.txt" }] }
        await emit({
          type: "tool_execution_end",
          toolCallId: "acceptance-write",
          toolName: "write",
          result,
          isError: false,
        })
        const tool = {
          role: "toolResult",
          toolCallId: "acceptance-write",
          toolName: "write",
          ...result,
          isError: false,
          timestamp: Date.now(),
        }
        await saveMessage(tool)
        await emit({ type: "message_end", message: tool })
      }
      await emit({
        type: "message_start",
        message: { role: "assistant", content: [], timestamp: Date.now() },
      })
      await emit({
        type: "message_update",
        assistantMessageEvent: {
          type: "thinking_delta",
          contentIndex: 1,
          delta: "Fixture thinking",
        },
      })
      await emit({
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Fixture reply" },
      })
      setTimeout(() => {
        if (!streaming) return
        const assistant = {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Fixture thinking" },
            { type: "text", text: "Fixture reply" },
          ],
          stopReason: "stop",
          timestamp: Date.now(),
        }
        void saveMessage(assistant)
          .then(() => emit({ type: "message_end", message: assistant }))
          .then(() => emit({ type: "agent_end", messages: [assistant], willRetry: false }))
          .then(() => emit({ type: "agent_settled", aborted: false }))
        streaming = false
      }, 40)
      return
    }
    case "extension_ui_response":
      if (pendingDialogCommand && command.id === pendingDialogID) {
        pendingDialogCount -= 1
        if (pendingDialogCount > 0 && command.cancelled !== true) {
          pendingDialogID = "fixture-dialog-second"
          await emit({
            type: "extension_ui_request",
            id: pendingDialogID,
            method: "select",
            title: "Second fixture selection",
            options: ["First", "Second"],
          })
        } else {
          const pending = pendingDialogCommand
          pendingDialogCommand = undefined
          await response(pending, { disposition: "handled" })
        }
      }
      await emit({ type: "fixture_answer", answer: command })
      return
    case "fixture_null":
      await response(command, null)
      return
    case "fixture_echo":
      await response(command, { value: command.value })
      return
    case "fixture_error":
      await emit({
        type: "response",
        id: command.id,
        command: command.type,
        success: false,
        error: command.error,
      })
      return
    case "fixture_mismatch":
      await emit({ type: "response", id: command.id, command: "wrong", success: true })
      return
    case "fixture_crash":
      return process.exit(9)
    case "fixture_no_response":
      return
    case "fixture_delayed":
      setTimeout(() => {
        void response(command, "late")
      }, 80)
      return
    case "fixture_events":
      if (Array.isArray(command.events)) for (const event of command.events) await emit(event)
      await response(command)
      return
    case "fixture_split": {
      const bytes = Buffer.from('{"type":"fixture_text","text":"é🙂\u2028\u2029"}\r\n')
      for (const byte of bytes) {
        await write(new Uint8Array([byte]))
        await Bun.sleep(1)
      }
      await response(command)
      return
    }
    case "fixture_raw":
      await write(String(command.raw))
      await response(command)
      return
    case "fixture_invalid_utf8":
      await write(new Uint8Array([123, 34, 116, 121, 112, 101, 34, 58, 34, 255, 34, 125, 10]))
      return
    case "fixture_oversize":
      await write(Buffer.alloc(8 * 1024 * 1024 + 1, 120))
      return
    case "fixture_unterminated":
      await write('{"type":"unfinished"}')
      return process.exit(0)
    case "fixture_stderr":
      for (let count = 0; count < 128; count++)
        await write("private-provider-secret".repeat(4096), true)
      await response(command)
      return
    case "fixture_flood":
      // One event-loop turn deliberately exceeds the client's bounded delivery queue.
      await write(Array.from({ length: 4096 }, () => '{"type":"fixture_tick"}\n').join(""))
      await response(command)
      return
    default:
      await response(command)
      return
  }
}

let buffer = ""
const decoder = new TextDecoder()
for await (const chunk of Bun.stdin.stream()) {
  buffer += decoder.decode(chunk, { stream: true })
  let lf = buffer.indexOf("\n")
  while (lf >= 0) {
    const line = buffer.slice(0, lf)
    buffer = buffer.slice(lf + 1)
    const command = JSON.parse(line)
    if (command.message === "CLI fixture: delayed preflight")
      void handle(command).catch(() => process.exit(8))
    else await handle(command)
    lf = buffer.indexOf("\n")
  }
}
if (mode !== "ignore-shutdown") clearInterval(keepAlive)
