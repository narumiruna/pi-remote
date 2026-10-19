import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process"
import { isAbsolute } from "node:path"

export const RPC_LIMITS = Object.freeze({
  recordBytes: 8 * 1024 * 1024,
  commandBytes: 1024 * 1024,
  writeBytes: 2 * 1024 * 1024,
  writeCount: 64,
  pendingCount: 128,
  eventBytes: 16 * 1024 * 1024,
  eventCount: 256,
  startupMs: 10_000,
  requestMs: 30_000,
  dialogMs: 300_000,
  controlMs: 1000,
  gracefulMs: 500,
  termMs: 500,
  killMs: 1000,
})

export class RPCError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = "RPCError"
  }
}

export interface PiRPCOptions {
  entry: string
  cwd: string
  args: string[]
  env?: Record<string, string>
  onEvent: (event: Record<string, unknown>) => void
  onExit?: () => void
  onFault?: (error: Error) => void
}

type Pending = {
  command: string
  resolve: (value: unknown) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
  expire: () => void
  cleanup: () => void
}
type Write = {
  bytes: Buffer
  active: () => boolean
  resolve: () => void
  reject: (error: Error) => void
}

const unknownOutcome = () =>
  new RPCError("unknownOutcome", "Pi command outcome is unknown. Inspect state before retrying.")
const invalidRequest = () => new RPCError("invalidRequest", "Pi rejected the command.")

/** Private subprocess boundary. Never include protocol payloads or stderr in errors. */
export class PiRPC {
  private child?: ChildProcessWithoutNullStreams
  private starting?: Promise<void>
  private stopping?: Promise<void>
  private closed = false
  private faulted = false
  private ready = false
  private nextId = 0
  private pending = new Map<string, Pending>()
  private writes: Write[] = []
  private writing = false
  private writeBytes = 0
  private writeCount = 0
  private fragment = Buffer.alloc(8192)
  private fragmentBytes = 0
  private events: { event: Record<string, unknown>; bytes: number }[] = []
  private eventBytes = 0
  private eventTask?: ReturnType<typeof setImmediate>
  private exitPromise?: Promise<void>

  constructor(private readonly options: PiRPCOptions) {}

  static async start(options: PiRPCOptions): Promise<PiRPC> {
    const rpc = new PiRPC(options)
    await rpc.start()
    return rpc
  }

  get childPid(): number | undefined {
    return this.child?.pid
  }

  start(): Promise<void> {
    this.starting ??= this.launch()
    return this.starting
  }

  private async launch(): Promise<void> {
    if (this.closed || !isAbsolute(this.options.entry) || !isAbsolute(this.options.cwd)) {
      throw new RPCError("invalidRequest", "Pi entry and working directory must be absolute paths.")
    }
    try {
      this.child = spawn(
        process.execPath,
        [this.options.entry, "--mode", "rpc", ...this.options.args],
        {
          cwd: this.options.cwd,
          env: { ...process.env, ...this.options.env },
          stdio: ["pipe", "pipe", "pipe"],
          shell: false,
        },
      )
      const child = this.child
      this.exitPromise = new Promise<void>((resolve) => {
        // exit confirms termination even if an inherited pipe remains open in a descendant.
        child.once("exit", () => {
          this.didExit()
          resolve()
        })
        child.on("error", () => {
          if (child.pid === undefined) {
            this.fail(new RPCError("unavailable", "Cannot start the Pi subprocess."))
            this.didExit()
            resolve()
          } else {
            // A failed signal is not proof of termination. Only exit confirms a spawned child.
            this.fail(unknownOutcome())
          }
        })
      })
      child.stdout.on("data", (chunk: Buffer) => this.readBytes(chunk))
      child.stdout.once("end", () => {
        if (this.fragmentBytes > 0 && !this.stopping) this.protocolFault()
        else if (!this.closed && !this.stopping) this.fail(unknownOutcome())
      })
      child.stdout.on("error", () => this.fail(unknownOutcome()))
      // Drain and discard. Do not log, retain, or parse private diagnostics.
      child.stderr.on("data", () => {})
      child.stderr.on("error", () => this.fail(unknownOutcome()))
      child.stdin.on("error", () => {
        if (!this.stopping) this.fail(unknownOutcome())
      })
      const state = await this.sendRequest("get_state", {}, RPC_LIMITS.startupMs)
      if (!isRecord(state) || typeof state.isStreaming !== "boolean") this.protocolFault()
      if (this.faulted || this.closed || this.stopping) throw unknownOutcome()
      this.ready = true
    } catch (error) {
      await this.shutdown()
      throw error instanceof RPCError
        ? error
        : new RPCError("unavailable", "Cannot start the Pi subprocess.")
    }
  }

  request(
    command: string,
    fields: Record<string, unknown> = {},
    timeoutMs: number = RPC_LIMITS.requestMs,
    signal?: AbortSignal,
  ): Promise<unknown> {
    if (!this.ready) return Promise.reject(new RPCError("unavailable", "Pi is not ready."))
    return this.sendRequest(command, fields, timeoutMs, signal)
  }

  private sendRequest(
    command: string,
    fields: Record<string, unknown>,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<unknown> {
    if (this.closed || this.stopping || this.faulted) return Promise.reject(unknownOutcome())
    if (
      !command ||
      !Number.isFinite(timeoutMs) ||
      timeoutMs <= 0 ||
      this.pending.size >= RPC_LIMITS.pendingCount
    ) {
      return Promise.reject(
        new RPCError("invalidRequest", "Pi request admission limit or deadline is invalid."),
      )
    }
    if (signal?.aborted) return Promise.reject(unknownOutcome())
    const id = `rpc-${++this.nextId}`
    let bytes: Buffer
    try {
      bytes = this.encode({ ...fields, type: command, id })
    } catch (error) {
      return Promise.reject(error)
    }
    if (
      this.writeCount >= RPC_LIMITS.writeCount ||
      this.writeBytes + bytes.length > RPC_LIMITS.writeBytes
    ) {
      return Promise.reject(
        new RPCError("invalidRequest", "Pi command queue is full. Command was not sent."),
      )
    }
    return new Promise((resolve, reject) => {
      const expire = () => {
        const pending = this.takePending(id)
        pending?.reject(unknownOutcome())
      }
      const timer = setTimeout(expire, timeoutMs)
      const cleanup = () => signal?.removeEventListener("abort", expire)
      this.pending.set(id, { command, resolve, reject, timer, expire, cleanup })
      signal?.addEventListener("abort", expire, { once: true })
      void this.enqueue(bytes, () => this.pending.has(id)).catch((error: Error) => {
        this.takePending(id)?.reject(error)
      })
    })
  }

  /** Only pending prompt acceptance can wait for host-validated dialog interaction. */
  setPromptResponseTimeout(timeoutMs: number): void {
    if (
      !Number.isFinite(timeoutMs) ||
      timeoutMs <= 0 ||
      timeoutMs > RPC_LIMITS.dialogMs + RPC_LIMITS.requestMs
    )
      throw invalidRequest()
    for (const pending of this.pending.values()) {
      if (pending.command !== "prompt") continue
      clearTimeout(pending.timer)
      pending.timer = setTimeout(pending.expire, timeoutMs)
    }
  }

  /** Extension UI responses have no normal response. The coordinator checks dialog lifetime. */
  async answer(fields: Record<string, unknown>): Promise<void> {
    if (!this.ready || this.closed || this.stopping || this.faulted) throw unknownOutcome()
    if (typeof fields.id !== "string" || fields.id.length === 0) throw invalidRequest()
    const bytes = this.encode({ ...fields, type: "extension_ui_response" })
    let active = true,
      timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        this.enqueue(bytes, () => active),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            active = false
            const error = unknownOutcome()
            this.fail(error)
            reject(error)
          }, RPC_LIMITS.controlMs)
        }),
      ])
    } finally {
      active = false
      clearTimeout(timer)
    }
  }

  private encode(record: Record<string, unknown>): Buffer {
    let text: string
    try {
      text = JSON.stringify(record)
    } catch {
      throw invalidRequest()
    }
    if (Buffer.byteLength(text) + 1 > RPC_LIMITS.commandBytes) {
      throw new RPCError("invalidRequest", "Pi command exceeds the byte limit.")
    }
    return Buffer.from(`${text}\n`)
  }

  private enqueue(bytes: Buffer, active: () => boolean): Promise<void> {
    if (
      this.writeCount >= RPC_LIMITS.writeCount ||
      this.writeBytes + bytes.length > RPC_LIMITS.writeBytes
    ) {
      return Promise.reject(
        new RPCError("invalidRequest", "Pi command queue is full. Command was not sent."),
      )
    }
    this.writeCount++
    this.writeBytes += bytes.length
    return new Promise((resolve, reject) => {
      this.writes.push({ bytes, active, resolve, reject })
      this.pumpWrites()
    })
  }

  private pumpWrites(): void {
    if (this.writing || this.closed || this.stopping || this.faulted) return
    const write = this.writes.shift()
    if (!write) return
    const finish = (error?: Error | null) => {
      this.writeCount--
      this.writeBytes -= write.bytes.length
      this.writing = false
      if (error) write.reject(unknownOutcome())
      else write.resolve()
      this.pumpWrites()
    }
    if (!write.active()) {
      finish()
      return
    }
    const input = this.child?.stdin
    if (!input || input.destroyed) {
      finish(unknownOutcome())
      return
    }
    this.writing = true
    // The callback waits for the stream's write completion. Only one write is outstanding.
    try {
      input.write(write.bytes, finish)
    } catch {
      finish(unknownOutcome())
      this.fail(unknownOutcome())
    }
  }

  private readBytes(chunk: Buffer): void {
    if (this.faulted) return
    let offset = 0
    while (offset < chunk.length) {
      const lf = chunk.indexOf(10, offset)
      const end = lf < 0 ? chunk.length : lf
      const part = chunk.subarray(offset, end)
      this.fragmentBytes += part.length
      if (this.fragmentBytes > RPC_LIMITS.recordBytes) {
        this.protocolFault()
        return
      }
      if (this.fragmentBytes > this.fragment.length) {
        const grown = Buffer.alloc(
          Math.min(RPC_LIMITS.recordBytes, Math.max(this.fragmentBytes, this.fragment.length * 2)),
        )
        this.fragment.copy(grown, 0, 0, this.fragmentBytes - part.length)
        this.fragment = grown
      }
      part.copy(this.fragment, this.fragmentBytes - part.length)
      if (lf < 0) return
      let record = this.fragment.subarray(0, this.fragmentBytes)
      this.fragmentBytes = 0
      if (record.at(-1) === 13) record = record.subarray(0, -1)
      this.readRecord(record)
      if (this.faulted) return
      offset = lf + 1
    }
  }

  private readRecord(bytes: Buffer): void {
    let record: unknown
    try {
      record = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))
    } catch {
      this.protocolFault()
      return
    }
    if (!isRecord(record) || typeof record.type !== "string" || record.type.length === 0) {
      this.protocolFault()
      return
    }
    if (record.type === "response") {
      if (
        typeof record.id !== "string" ||
        typeof record.command !== "string" ||
        typeof record.success !== "boolean" ||
        (record.success === false && typeof record.error !== "string")
      ) {
        this.protocolFault()
        return
      }
      const pending = this.pending.get(record.id)
      if (!pending) {
        // A deadline or cancellation can precede its response. Never retry or deliver it as an event.
        const match = /^rpc-([1-9][0-9]*)$/.exec(record.id)
        if (!match || Number(match[1]) > this.nextId) this.protocolFault()
        return
      }
      if (record.command !== pending.command) {
        this.protocolFault()
        return
      }
      this.takePending(record.id)
      if (record.success) pending.resolve(record.data)
      else {
        const auth =
          typeof record.error === "string" &&
          /api.?key|authenticat|unauthoriz|not logged in|credential/i.test(record.error)
        pending.reject(
          auth
            ? new RPCError(
                "providerAuthenticationRequired",
                "Pi provider authentication is required.",
              )
            : invalidRequest(),
        )
      }
      return
    }
    if (this.stopping || this.closed) return
    if (
      this.events.length >= RPC_LIMITS.eventCount ||
      this.eventBytes + bytes.length > RPC_LIMITS.eventBytes
    ) {
      this.fail(
        new RPCError(
          "unknownOutcome",
          "Pi event delivery overflowed. Recover a snapshot before continuing.",
        ),
      )
      return
    }
    this.events.push({ event: record, bytes: bytes.length })
    this.eventBytes += bytes.length
    this.eventTask ??= setImmediate(() => this.deliverEvents())
  }

  private deliverEvents(): void {
    this.eventTask = undefined
    for (let count = 0; count < 32 && this.events.length; count++) {
      const item = this.events.shift()
      if (!item) break
      this.eventBytes -= item.bytes
      try {
        this.options.onEvent(item.event)
      } catch {
        this.fail(
          new RPCError(
            "unknownOutcome",
            "Pi event consumer failed. Recover state before continuing.",
          ),
        )
        return
      }
    }
    if (this.events.length) this.eventTask = setImmediate(() => this.deliverEvents())
  }

  private takePending(id: string): Pending | undefined {
    const pending = this.pending.get(id)
    if (!pending) return
    this.pending.delete(id)
    clearTimeout(pending.timer)
    pending.cleanup()
    return pending
  }

  private rejectOutstanding(error: Error): void {
    for (const id of this.pending.keys()) this.takePending(id)?.reject(error)
    for (const write of this.writes.splice(0)) {
      this.writeCount--
      this.writeBytes -= write.bytes.length
      write.reject(error)
    }
  }

  private protocolFault(): void {
    this.fail(
      new RPCError(
        "unknownOutcome",
        "Pi emitted an invalid RPC record. The managed process was stopped.",
      ),
    )
  }

  private fail(error: RPCError): void {
    if (this.faulted || this.closed || this.stopping) return
    this.faulted = true
    this.rejectOutstanding(error)
    this.events = []
    this.eventBytes = 0
    this.fragment = Buffer.alloc(0)
    this.fragmentBytes = 0
    if (this.eventTask) clearImmediate(this.eventTask)
    this.eventTask = undefined
    // Start cleanup before invoking user code, which must not prevent child termination.
    void this.shutdown().catch(() => {})
    try {
      this.options.onFault?.(error)
    } catch {
      /* No private callback errors in diagnostics. */
    }
  }

  private didExit(): void {
    if (this.closed) return
    this.closed = true
    this.ready = false
    this.rejectOutstanding(unknownOutcome())
    if (!this.stopping && !this.faulted) {
      try {
        this.options.onFault?.(unknownOutcome())
      } catch {
        /* Callback isolation. */
      }
    }
    try {
      this.options.onExit?.()
    } catch {
      /* Callback isolation. */
    }
  }

  shutdown(): Promise<void> {
    this.stopping ??= this.stopChild()
    return this.stopping
  }

  private async stopChild(): Promise<void> {
    this.ready = false
    this.rejectOutstanding(unknownOutcome())
    const child = this.child
    if (!child) {
      this.closed = true
      return
    }
    child.stdin.end()
    if (await this.waitForExit(RPC_LIMITS.gracefulMs)) return this.closePipes()
    try {
      child.kill("SIGTERM")
    } catch {
      /* Continue to the bounded kill attempt. */
    }
    if (await this.waitForExit(RPC_LIMITS.termMs)) return this.closePipes()
    try {
      child.kill("SIGKILL")
    } catch {
      /* The exit check below must still confirm termination. */
    }
    if (await this.waitForExit(RPC_LIMITS.killMs)) return this.closePipes()
    throw new RPCError("unknownOutcome", "Pi subprocess termination could not be confirmed.")
  }

  private closePipes(): void {
    this.child?.stdin.destroy()
    this.child?.stdout.destroy()
    this.child?.stderr.destroy()
  }

  private async waitForExit(ms: number): Promise<boolean> {
    if (this.closed) return true
    let timer: ReturnType<typeof setTimeout> | undefined
    const expired = new Promise<false>((resolve) => {
      timer = setTimeout(() => resolve(false), ms)
    })
    const exited = this.exitPromise?.then(() => true) ?? Promise.resolve(true)
    const result = await Promise.race([exited, expired])
    clearTimeout(timer)
    return result
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
