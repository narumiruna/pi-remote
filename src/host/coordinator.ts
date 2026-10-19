import { createHash, randomUUID } from "node:crypto"
import { mkdir, realpath } from "node:fs/promises"
import { join, resolve, sep } from "node:path"
import { DirectoryAccess } from "./directories.ts"
import { displayText, faultCode, foundationNow, object } from "./errors.ts"
import {
  type ClientPacket,
  enumValue,
  type HostSnapshot,
  initialSnapshot,
  type RemoteFault,
  type SessionInfo,
  uuid,
} from "./protocol.ts"
import { PiRPC, RPC_LIMITS } from "./rpc.ts"
import { Fault, type PrivateStorage } from "./storage.ts"
import { TranscriptReducer } from "./transcript.ts"

type Request = Extract<ClientPacket, { kind: "request" }>
type DirectoryRecord = { path: string; identity: string }
type Managed = {
  info: SessionInfo
  directory: DirectoryRecord
  piID: string
  file?: string
  hasHistory?: boolean
}
type Receipt = { digest: string; done: boolean; fault?: RemoteFault }
const reads = new Set(["snapshot", "synchronize", "directories", "directoryAtPath"])
const noSession = new Set([...reads, "createSession", "resumeSession"])
const supported = new Set([
  ...noSession,
  "closeSession",
  "prompt",
  "stop",
  "model",
  "thinking",
  "command",
  "answer",
])

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`
  if (value && typeof value === "object")
    return `{${Object.entries(value)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`)
      .join(",")}}`
  return JSON.stringify(value)
}

/** One serialized mutation authority, shared by all authenticated phones. */
export class Coordinator {
  readonly snapshot: HostSnapshot
  private sessions: Managed[] = []
  private receipts: Record<string, Receipt> = {}
  private child?: PiRPC
  private generation = 0
  private mutating = false
  private interrupting = false
  private closing = false
  private shutdownTask?: Promise<void>
  private activityRevision = 0
  private stopRevision = 0
  private pendingInputs = 0
  private unresolvedInput = false
  private reducer = new TranscriptReducer()
  private subscribers = new Set<(state: HostSnapshot) => void>()
  private replay: HostSnapshot[] = []
  private replayBytes = 0
  private publication?: ReturnType<typeof setTimeout>
  private dialogTimer?: ReturnType<typeof setInterval>
  private dialogIDs = new Map<string, number>()
  private persistence = Promise.resolve()
  private constructor(
    readonly storage: PrivateStorage,
    readonly directories: DirectoryAccess,
    readonly entry: string,
    private piArgs: string[],
    private env?: Record<string, string>,
  ) {
    this.snapshot = initialSnapshot(storage.catalogID, randomUUID().toUpperCase())
    this.snapshot.capabilities = [
      "directories",
      "directory-path",
      "sessions",
      "prompt",
      "steering",
      "follow-up",
      "stop",
      "models",
      "thinking",
      "thinking-display",
      "extension-dialogs",
      "close-session",
    ]
  }

  static async open(options: {
    storage: PrivateStorage
    directories: DirectoryAccess
    entry: string
    piArgs?: string[]
    env?: Record<string, string>
  }): Promise<Coordinator> {
    const host = new Coordinator(
      options.storage,
      options.directories,
      options.entry,
      options.piArgs ?? [],
      options.env,
    )
    const saved = await options.storage.readJSON("sessions.json")
    if (saved !== null) {
      const root = object(saved)
      if (root.version !== 1 || !Array.isArray(root.sessions) || root.sessions.length > 256)
        throw new Fault("storageFailure")
      const ids = new Set<string>()
      host.sessions = root.sessions.map((value): Managed => {
        const item = object(value),
          info = object(item.info),
          directory = object(item.directory)
        const id = uuid(info.id)
        if (
          ids.has(id) ||
          typeof info.title !== "string" ||
          Buffer.byteLength(info.title) > 128 ||
          typeof info.updated !== "number" ||
          !Number.isFinite(info.updated) ||
          typeof info.interrupted !== "boolean" ||
          typeof directory.path !== "string" ||
          !directory.path.startsWith("/") ||
          typeof directory.identity !== "string" ||
          info.directory !== directory.path
        )
          throw new Fault("storageFailure")
        ids.add(id)
        const file = item.file
        if (
          file !== undefined &&
          (typeof file !== "string" ||
            !file.startsWith(join(options.storage.path, "pi-sessions", id) + sep) ||
            !file.endsWith(".jsonl"))
        )
          throw new Fault("storageFailure")
        return {
          info: {
            id,
            title: info.title,
            directory: directory.path,
            updated: info.updated,
            interrupted: info.interrupted,
          },
          directory: { path: directory.path, identity: directory.identity },
          piID: uuid(item.piID),
          hasHistory: item.hasHistory === true,
          ...(typeof file === "string" ? { file } : {}),
        }
      })
    }
    host.refreshSessions()
    await host.saveJournal()
    host.dialogTimer = setInterval(() => host.expireDialogs(), 250)
    host.dialogTimer.unref()
    host.publish()
    return host
  }

  setVersion(version: string): void {
    this.snapshot.piVersion = displayText(version, 128)
    this.publish()
  }
  subscribe(listener: (state: HostSnapshot) => void): () => void {
    this.subscribers.add(listener)
    return () => this.subscribers.delete(listener)
  }
  private refreshSessions(): void {
    this.snapshot.sessions = this.sessions
      .map((s) => ({ ...s.info }))
      .sort((a, b) => b.updated - a.updated)
  }
  private saveCatalog(): Promise<void> {
    this.refreshSessions()
    const value = structuredClone({ version: 1, sessions: this.sessions })
    const result = this.persistence.then(() => this.storage.writeJSON("sessions.json", value))
    this.persistence = result.catch(() => {
      // Disk failure cannot establish idle or authorize Close on a still-running child.
      this.snapshot.error = "unknownOutcome"
      const notice =
        "Private session storage failed. Use Stop before changing sessions, then check disk access."
      this.snapshot.notices = [
        ...this.snapshot.notices.filter((value) => value !== notice).slice(-7),
        notice,
      ]
    })
    return result
  }
  private saveJournal(): Promise<void> {
    return this.storage.writeJSON(
      "requests.json",
      { epoch: this.snapshot.epoch, records: this.receipts },
      4 * 1024 * 1024,
    )
  }
  private selected(): Managed {
    const item = this.sessions.find((s) => s.info.id === this.snapshot.selected)
    if (!item) throw new Fault("conflict")
    return item
  }
  private rpc(): PiRPC {
    if (!this.child) throw new Fault("unavailable")
    return this.child
  }
  private working(): boolean {
    return !["idle", "interrupted", "unavailable"].includes(this.snapshot.phase)
  }
  private assertIdle(): void {
    if (this.working() || this.snapshot.dialogs.length || this.snapshot.error === "unknownOutcome")
      throw new Fault("busy")
  }

  wireSnapshot(): HostSnapshot {
    const state = structuredClone(this.snapshot)
    const limit = 2 * 1024 * 1024 - 1024
    let bytes = Buffer.byteLength(JSON.stringify(state))
    let omitted = false
    while (bytes > limit && state.messages.length) {
      const removed = state.messages.shift()
      bytes -= Buffer.byteLength(JSON.stringify(removed)) + 1
      omitted = true
    }
    if (bytes > limit) {
      const minimal = initialSnapshot(state.host, state.epoch)
      minimal.sequence = state.sequence
      minimal.piVersion = state.piVersion
      minimal.selected = state.selected
      minimal.phase = state.phase
      minimal.sessions = state.sessions.filter((session) => session.id === state.selected)
      minimal.capabilities = ["directories", "directory-path", "sessions", "stop", "close-session"]
      minimal.error = state.error === "unknownOutcome" ? "unknownOutcome" : "capacity"
      minimal.notices = [
        "Host display metadata exceeds its limit. Use Stop, inspect the saved session, or use a smaller catalog.",
      ]
      minimal.hasOlderMessages = true
      return minimal
    }
    if (omitted) {
      state.hasOlderMessages = true
      state.notices = [
        ...state.notices.slice(-7),
        "Older conversation display was omitted to keep synchronization within its size limit.",
      ]
    }
    return state
  }

  private publish(): void {
    if (this.closing) return
    if (this.publication) {
      clearTimeout(this.publication)
      this.publication = undefined
    }
    if (this.snapshot.sequence >= Number.MAX_SAFE_INTEGER) {
      void this.shutdown()
      return
    }
    this.snapshot.sequence += 1
    const state = this.wireSnapshot()
    const size = Buffer.byteLength(JSON.stringify(state))
    this.replay.push(state)
    this.replayBytes += size
    while (this.replay.length > 32 || this.replayBytes > 2 * 1024 * 1024) {
      const removed = this.replay.shift()
      if (removed) this.replayBytes -= Buffer.byteLength(JSON.stringify(removed))
    }
    for (const listener of this.subscribers) listener(state)
  }
  private schedulePublish(): void {
    if (!this.publication) this.publication = setTimeout(() => this.publish(), 30)
  }

  async handle(
    request: Request,
    device: string,
    authorized: () => boolean,
  ): Promise<Record<string, unknown>> {
    if (this.closing || !authorized()) return enumValue("failure", "unauthorized")
    if (request.epoch !== this.snapshot.epoch) return enumValue("failure", "unknownOutcome")
    if (!supported.has(request.action)) return enumValue("failure", "unsupportedFeature")
    if (
      !noSession.has(request.action) &&
      (!request.session || request.session !== this.snapshot.selected)
    )
      return enumValue("failure", "conflict")
    const mutation = !reads.has(request.action)
    const requestStopRevision = this.stopRevision
    const key = `${device}/${request.id}`
    const digest = createHash("sha256").update(canonical(request)).digest("hex")
    if (mutation && this.receipts[key]) {
      const previous = this.receipts[key]
      if (previous.digest !== digest) return enumValue("failure", "conflict")
      return previous.done
        ? previous.fault
          ? enumValue("failure", previous.fault)
          : enumValue("ok")
        : enumValue("failure", "unknownOutcome")
    }
    const interrupt = request.action === "answer" || request.action === "stop"
    if (mutation && ((this.mutating && !interrupt) || this.interrupting))
      return enumValue("failure", "busy")
    if (mutation) {
      if (Object.keys(this.receipts).length >= 10_000) {
        if (request.action === "stop")
          return this.stopAtCapacity(request, authorized, requestStopRevision)
        return enumValue("failure", "capacity")
      }
      if (interrupt) this.interrupting = true
      else this.mutating = true
      if (request.action === "stop") this.stopRevision += 1
      this.receipts[key] = { digest, done: false }
    }
    let performed = false
    let stopReceiptFailed = false
    try {
      if (mutation) {
        try {
          await this.saveJournal()
        } catch (error) {
          if (request.action !== "stop") throw error
          // Receipt storage must not block authorized emergency cleanup.
          stopReceiptFailed = true
          this.unresolvedInput = true
        }
      }
      if (!authorized() || this.closing) throw new Fault("unauthorized")
      const result = await this.perform(request, authorized, requestStopRevision)
      performed = true
      if (mutation) {
        this.receipts[key].done = true
        try {
          await this.saveJournal()
        } catch (error) {
          if (request.action !== "stop") throw error
          stopReceiptFailed = true
        }
        if (stopReceiptFailed) {
          this.snapshot.error = "storageFailure"
          const notice =
            "One or more Stop receipt writes failed. Work stopped. Check disk space and catalog access."
          this.snapshot.notices = [
            ...this.snapshot.notices.filter((value) => value !== notice).slice(-7),
            notice,
          ]
        }
        this.publish()
      }
      return result
    } catch (error) {
      const fault = performed && mutation ? "unknownOutcome" : faultCode(error)
      if (mutation) {
        this.receipts[key] = { digest, done: true, fault }
        try {
          await this.saveJournal()
        } catch {
          this.snapshot.error = "unknownOutcome"
          this.publish()
          return enumValue("failure", "unknownOutcome")
        }
        const interruptedInput =
          (request.action === "prompt" || request.action === "command") &&
          requestStopRevision !== this.stopRevision
        if (
          !interruptedInput &&
          (this.snapshot.error !== "unknownOutcome" || fault === "unknownOutcome")
        )
          this.snapshot.error = fault
        if (this.snapshot.phase === "starting") this.snapshot.phase = "unavailable"
        this.publish()
      }
      return enumValue("failure", fault)
    } finally {
      if (mutation) {
        if (interrupt) this.interrupting = false
        else this.mutating = false
      }
    }
  }

  private async stopAtCapacity(
    request: Request,
    authorized: () => boolean,
    requestStopRevision: number,
  ): Promise<Record<string, unknown>> {
    this.interrupting = true
    try {
      if (!authorized() || this.closing) throw new Fault("unauthorized")
      this.stopRevision += 1
      // No new work can be admitted until restart. Stop the runtime instead of
      // growing the receipt table or evicting receipts for earlier work.
      this.unresolvedInput = true
      const result = await this.perform(request, authorized, requestStopRevision)
      this.snapshot.error = "capacity"
      const notice =
        "Receipt storage is full. Work stopped. Restart the host before sending more work."
      this.snapshot.notices = [
        ...this.snapshot.notices.filter((value) => value !== notice).slice(-7),
        notice,
      ]
      this.publish()
      return result
    } catch (error) {
      const fault = faultCode(error)
      this.snapshot.error = fault
      this.publish()
      return enumValue("failure", fault)
    } finally {
      this.interrupting = false
    }
  }

  private async perform(
    request: Request,
    authorized: () => boolean,
    requestStopRevision: number,
  ): Promise<Record<string, unknown>> {
    const f = request.fields
    switch (request.action) {
      case "snapshot":
        return enumValue("snapshot", this.wireSnapshot())
      case "synchronize": {
        const after = f.after as number | undefined
        const first = this.replay[0]
        if (
          f.epoch === this.snapshot.epoch &&
          after !== undefined &&
          after <= this.snapshot.sequence &&
          first &&
          after >= first.sequence - 1
        )
          return enumValue("synchronized", {
            events: this.replay.filter((s) => s.sequence > after),
          })
        return enumValue("synchronized", { snapshot: this.wireSnapshot(), events: [] })
      }
      case "directories":
        return enumValue(
          "directories",
          await this.directories.list(f.id as string | undefined, f.cursor as string | undefined),
        )
      case "directoryAtPath":
        return enumValue("directories", await this.directories.atPath(f.path as string))
      case "createSession": {
        this.assertIdle()
        if (this.sessions.length >= 256) throw new Fault("capacity")
        const directory = await this.directories.resolve(f.directory as string)
        if (!authorized() || this.closing) throw new Fault("unauthorized")
        const id = randomUUID().toUpperCase()
        const item: Managed = {
          info: {
            id,
            title: displayText(directory.path.split(sep).filter(Boolean).at(-1) ?? "Session", 128),
            directory: directory.path,
            updated: foundationNow(),
            interrupted: false,
          },
          directory,
          piID: randomUUID().toUpperCase(),
        }
        this.sessions.push(item)
        await this.saveCatalog()
        await this.activate(item, authorized, requestStopRevision)
        return enumValue("ok")
      }
      case "resumeSession": {
        this.assertIdle()
        const item = this.sessions.find((s) => s.info.id === f.id)
        if (!item) throw new Fault("invalidRequest")
        await this.activate(item, authorized, requestStopRevision)
        return enumValue("ok")
      }
      case "closeSession":
        this.assertIdle()
        this.generation += 1
        await this.child?.shutdown()
        this.child = undefined
        this.snapshot.selected = undefined
        this.snapshot.draft = undefined
        this.snapshot.draftID = undefined
        this.snapshot.phase = "idle"
        this.snapshot.messages = []
        this.snapshot.hasOlderMessages = false
        this.snapshot.dialogs = []
        this.snapshot.error = undefined
        this.reducer.clear()
        this.dialogIDs.clear()
        return enumValue("ok")
      case "prompt":
      case "command": {
        const stopRevision = this.stopRevision
        if (this.snapshot.error === "unknownOutcome") throw new Fault("unknownOutcome")
        if (f.image) throw new Fault("unsupportedFeature")
        let message: string
        let command = "prompt"
        if (request.action === "command") {
          const name = f.name as string
          const discovered = this.snapshot.commands.find((c) => c.name === name)
          if (!discovered) throw new Fault("unsupportedFeature")
          if (this.working()) {
            if (discovered.source !== "extension" || this.snapshot.dialogs.length)
              throw new Fault("busy")
          } else this.assertIdle()
          message = `/${name}${f.arguments ? ` ${f.arguments}` : ""}`
        } else {
          message = f.text as string
          const delivery = f.delivery as string
          if (!message.trim() || Buffer.byteLength(message) > 64 * 1024)
            throw new Fault("invalidRequest")
          if (this.working()) {
            if (delivery === "prompt") throw new Fault("busy")
            command = delivery === "steer" ? "steer" : "follow_up"
          } else if (delivery !== "prompt") throw new Fault("conflict")
        }
        const item = this.selected()
        item.info.interrupted = true
        await this.saveCatalog()
        if (!authorized() || this.closing) throw new Fault("unauthorized")
        if (stopRevision !== this.stopRevision) throw new Fault("cancelled")
        const before = this.activityRevision
        const previousPhase = this.snapshot.phase
        if (command === "prompt") {
          this.snapshot.phase = "working"
          this.publish()
        }
        let data: Record<string, unknown>
        this.pendingInputs += 1
        try {
          data = object(await this.rpc().request(command, { message }))
        } catch (error) {
          const code = faultCode(error)
          if (code === "unknownOutcome") this.unresolvedInput = true
          if (
            this.activityRevision === before &&
            stopRevision === this.stopRevision &&
            (code === "invalidRequest" || code === "providerAuthenticationRequired")
          ) {
            this.snapshot.phase = previousPhase
            item.info.interrupted = !["idle", "interrupted", "unavailable"].includes(previousPhase)
            await this.saveCatalog()
          }
          throw error
        } finally {
          this.pendingInputs -= 1
        }
        if (
          command === "prompt" &&
          stopRevision === this.stopRevision &&
          data.disposition === "handled" &&
          this.activityRevision === before
        ) {
          this.snapshot.phase = previousPhase
          item.info.interrupted = !["idle", "interrupted", "unavailable"].includes(previousPhase)
          await this.saveCatalog()
        }
        return enumValue("ok")
      }
      case "stop": {
        const rpc = this.child
        const uncertainInput = this.unresolvedInput || this.snapshot.error === "unknownOutcome"
        if (!rpc) {
          this.recoverStoppedChild()
          return enumValue("ok")
        }
        this.snapshot.phase = "stopping"
        this.publish()
        try {
          for (const dialog of this.snapshot.dialogs)
            await rpc.answer({ id: dialog.id, cancelled: true })
          this.snapshot.dialogs = []
          this.dialogIDs.clear()
          await rpc.request("clear_queue", {}, RPC_LIMITS.controlMs)
          await rpc.request("abort", {}, RPC_LIMITS.controlMs)
          const state = object(await rpc.request("get_state", {}, RPC_LIMITS.controlMs))
          if (uncertainInput || this.pendingInputs > 0 || this.unresolvedInput) {
            this.generation += 1
            await rpc.shutdown()
            this.child = undefined
            this.recoverStoppedChild()
            await this.saveCatalog()
            return enumValue("ok")
          }
          if (state.isStreaming !== false || state.isCompacting !== false)
            throw new Fault("unknownOutcome")
          this.snapshot.phase = "idle"
          this.snapshot.pendingMessages = 0
          this.snapshot.dialogs = []
          this.dialogIDs.clear()
          this.snapshot.error = undefined
          this.selected().info.interrupted = false
          await this.saveCatalog()
        } catch {
          this.generation += 1
          await rpc.shutdown()
          this.child = undefined
          this.recoverStoppedChild()
          return enumValue("ok")
        }
        return enumValue("ok")
      }
      case "model":
        this.assertIdle()
        await this.rpc().request("set_model", { provider: f.provider, modelId: f.id })
        await this.refreshConfiguration()
        return enumValue("ok")
      case "thinking":
        this.assertIdle()
        if (!this.snapshot.thinkingLevels.includes(f.level as string))
          throw new Fault("invalidRequest")
        await this.rpc().request("set_thinking_level", { level: f.level })
        await this.refreshConfiguration()
        return enumValue("ok")
      case "answer": {
        const id = f.dialog as string
        const expiry = this.dialogIDs.get(id)
        const dialog = this.snapshot.dialogs.find((d) => d.id === id)
        if (expiry === undefined || expiry <= performance.now() || !dialog)
          throw new Fault("expired")
        if (
          dialog.method === "select" &&
          !f.cancelled &&
          !dialog.options.includes(f.value as string)
        )
          throw new Fault("invalidRequest")
        if (typeof f.value === "string" && Buffer.byteLength(f.value) > 64 * 1024)
          throw new Fault("tooLarge")
        this.dialogIDs.delete(id)
        this.snapshot.dialogs = this.snapshot.dialogs.filter((d) => d.id !== id)
        this.updatePromptResponseTimeout()
        await this.rpc().answer({
          id,
          value: f.value,
          confirmed: f.confirmed,
          cancelled: f.cancelled,
        })
        return enumValue("ok")
      }
      default:
        throw new Fault("unsupportedFeature")
    }
  }

  private async activate(
    item: Managed,
    authorized: () => boolean,
    stopRevision: number,
  ): Promise<void> {
    const check = () => {
      if (stopRevision !== this.stopRevision) throw new Fault("cancelled")
      if (!authorized() || this.closing) throw new Fault("unauthorized")
    }
    await DirectoryAccess.validate(item.directory)
    check()
    const generation = ++this.generation
    await this.child?.shutdown()
    check()
    this.child = undefined
    this.reducer.clear()
    this.snapshot.messages = []
    this.snapshot.hasOlderMessages = false
    this.snapshot.draft = undefined
    this.snapshot.draftID = undefined
    this.snapshot.dialogs = []
    this.dialogIDs.clear()
    this.snapshot.selected = item.info.id
    this.snapshot.phase = "starting"
    this.snapshot.error = undefined
    this.publish()
    const folder = join(this.storage.path, "pi-sessions", item.info.id)
    await mkdir(folder, { recursive: true, mode: 0o700 })
    const args = [...this.piArgs, "--session-dir", folder]
    if (
      item.file &&
      !(await Bun.file(item.file).exists()) &&
      !item.hasHistory &&
      !item.info.interrupted
    )
      item.file = undefined
    if (item.file) {
      const actual = await realpath(item.file).catch(() => {
        throw new Fault("staleDirectory")
      })
      if (!actual.startsWith((await realpath(folder)) + sep)) throw new Fault("staleDirectory")
      const file = Bun.file(actual)
      if (file.size > 64 * 1024 * 1024) throw new Fault("tooLarge")
      const prefix = await file.slice(0, 65536).text()
      const header = object(JSON.parse(prefix.split("\n")[0]))
      if (header.type !== "session" || header.id !== item.piID) throw new Fault("incompatiblePi")
      const cwd = await DirectoryAccess.identify(String(header.cwd))
      if (cwd.identity !== item.directory.identity || cwd.path !== item.directory.path)
        throw new Fault("staleDirectory")
      args.push("--session", actual)
    } else {
      args.push("--session-id", item.piID)
    }
    await DirectoryAccess.validate(item.directory)
    check()
    const rpc = new PiRPC({
      entry: this.entry,
      cwd: item.directory.path,
      args,
      env: this.env,
      onEvent: (event) => {
        if (generation === this.generation && !this.closing) this.event(event)
      },
      onExit: () => {
        if (generation === this.generation && !this.closing) this.ended()
      },
      onFault: () => {
        if (generation === this.generation && !this.closing) this.ended()
      },
    })
    this.child = rpc
    try {
      await rpc.start()
      check()
      await this.refreshConfiguration()
      check()
      const history = object(await rpc.request("get_messages"))
      check()
      this.reducer.replaceHistory(Array.isArray(history.messages) ? history.messages : [])
      this.snapshot.messages = this.reducer.messages
      this.snapshot.hasOlderMessages = this.reducer.omitted
      this.snapshot.phase = "idle"
      item.info.updated = foundationNow()
      await this.saveCatalog()
      check()
    } catch (error) {
      this.generation += 1
      await rpc.shutdown()
      this.child = undefined
      throw error
    }
  }

  private async refreshConfiguration(): Promise<void> {
    const rpc = this.rpc()
    const state = object(await rpc.request("get_state"))
    const models = object(await rpc.request("get_available_models"))
    const levels = object(await rpc.request("get_available_thinking_levels"))
    const commands = object(await rpc.request("get_commands"))
    this.snapshot.models = (Array.isArray(models.models) ? models.models : [])
      .slice(0, 256)
      .map((value) => {
        const m = object(value)
        return {
          provider: displayText(m.provider, 128),
          model: displayText(m.id, 256),
          name: displayText(m.name ?? m.id, 128),
        }
      })
    this.snapshot.thinkingLevels = (Array.isArray(levels.levels) ? levels.levels : [])
      .filter((v): v is string => typeof v === "string")
      .slice(0, 16)
    this.snapshot.thinking = displayText(state.thinkingLevel, 32)
    const model = state.model && typeof state.model === "object" ? object(state.model) : {}
    this.snapshot.model = `${displayText(model.provider, 128)}/${displayText(model.id, 256)}`
    this.snapshot.commands = (Array.isArray(commands.commands) ? commands.commands : [])
      .slice(0, 256)
      .map((value) => {
        const c = object(value)
        return {
          name: displayText(c.name, 128),
          detail: displayText(c.description, 256),
          source: displayText(c.source, 32),
        }
      })
    this.snapshot.pendingMessages =
      typeof state.pendingMessageCount === "number" &&
      Number.isSafeInteger(state.pendingMessageCount)
        ? state.pendingMessageCount
        : 0
    if (typeof state.sessionFile === "string") {
      const item = this.selected(),
        folder = resolve(this.storage.path, "pi-sessions", item.info.id)
      const reported = resolve(state.sessionFile)
      if (!reported.startsWith(folder + sep) || !reported.endsWith(".jsonl"))
        throw new Fault("incompatiblePi")
      item.file = reported
    }
  }

  private event(event: Record<string, unknown>): void {
    if (event.type === "agent_settled" && typeof event.aborted !== "boolean")
      throw new Fault("incompatiblePi")
    if (
      event.type === "queue_update" &&
      (!Array.isArray(event.steering) ||
        !Array.isArray(event.followUp) ||
        !event.steering.every((value) => typeof value === "string") ||
        !event.followUp.every((value) => typeof value === "string"))
    )
      throw new Fault("incompatiblePi")
    if (
      event.type === "compaction_start" &&
      !["manual", "threshold", "overflow"].includes(String(event.reason))
    )
      throw new Fault("incompatiblePi")
    if (
      event.type === "extension_ui_request" &&
      (typeof event.id !== "string" ||
        typeof event.method !== "string" ||
        (event.timeout !== undefined &&
          (typeof event.timeout !== "number" ||
            !Number.isFinite(event.timeout) ||
            event.timeout < 0)))
    )
      throw new Fault("incompatiblePi")
    this.reducer.consume(event)
    this.snapshot.messages = this.reducer.messages
    this.snapshot.hasOlderMessages = this.reducer.omitted
    if (event.type === "agent_start" || event.type === "agent_settled") this.activityRevision += 1
    if (event.type === "message_end" && this.snapshot.selected) this.selected().hasHistory = true
    switch (event.type) {
      case "agent_start":
        this.snapshot.phase = "working"
        break
      case "agent_settled":
        if (this.snapshot.error === "unknownOutcome") {
          this.snapshot.phase = "interrupted"
          break
        }
        this.snapshot.phase = "idle"
        this.snapshot.error = undefined
        if (this.snapshot.selected && this.pendingInputs === 0) {
          this.selected().info.interrupted = false
          void this.saveCatalog().catch(() => this.ended())
        }
        break
      case "compaction_start":
        this.snapshot.phase = "compacting"
        break
      case "summarization_retry_scheduled":
        this.snapshot.phase = "retrying"
        break
      case "queue_update":
        this.snapshot.pendingMessages =
          (Array.isArray(event.steering) ? event.steering.length : 0) +
          (Array.isArray(event.followUp) ? event.followUp.length : 0)
        break
      case "extension_ui_request":
        this.extension(event)
        break
    }
    this.schedulePublish()
  }

  private extension(event: Record<string, unknown>): void {
    const method = String(event.method),
      id = String(event.id)
    if (["select", "confirm", "input", "editor"].includes(method)) {
      const options = Array.isArray(event.options) ? event.options : []
      const unsafeSelection =
        method === "select" &&
        (!Array.isArray(event.options) ||
          options.length > 100 ||
          options.some(
            (value) =>
              typeof value !== "string" ||
              Buffer.byteLength(value) > 512 ||
              displayText(value, 512) !== value,
          ) ||
          new Set((options as string[]).map((value) => value.normalize("NFC"))).size !==
            options.length)
      if (unsafeSelection) {
        this.dialogIDs.delete(id)
        this.snapshot.dialogs = this.snapshot.dialogs.filter((dialog) => dialog.id !== id)
        this.snapshot.notices = [
          ...this.snapshot.notices.slice(-7),
          "Extension selection is unavailable because its options cannot be shown without changes. The request was cancelled.",
        ]
      }
      if (unsafeSelection || this.snapshot.dialogs.length >= 8 || id.length > 128) {
        this.updatePromptResponseTimeout()
        void this.rpc()
          .answer({ id, cancelled: true })
          .catch(() => this.ended())
        return
      }
      const duration =
        typeof event.timeout === "number"
          ? Math.max(0, Math.min(event.timeout, RPC_LIMITS.dialogMs))
          : RPC_LIMITS.dialogMs
      this.dialogIDs.set(id, performance.now() + duration)
      this.snapshot.dialogs = this.snapshot.dialogs.filter((d) => d.id !== id)
      this.snapshot.dialogs.push({
        id,
        method,
        title: displayText(event.title, 4096),
        message: displayText(event.message, 4096),
        options: method === "select" ? (options as string[]) : [],
        text: displayText(event.prefill ?? event.text, 64 * 1024),
        expires: foundationNow() + duration / 1000,
      })
      this.updatePromptResponseTimeout()
    } else if (method === "notify") {
      this.snapshot.notices = [...this.snapshot.notices.slice(-7), displayText(event.message, 4096)]
    } else if (method === "set_editor_text") {
      this.snapshot.draft = displayText(event.text, 64 * 1024)
      this.snapshot.draftID = randomUUID().toUpperCase()
    }
  }
  private updatePromptResponseTimeout(): void {
    const now = performance.now()
    const remaining = Math.max(now, ...this.dialogIDs.values()) - now
    this.child?.setPromptResponseTimeout(remaining + RPC_LIMITS.requestMs)
  }

  private expireDialogs(): void {
    if (this.closing) return
    let expired = false
    for (const [id, expiry] of this.dialogIDs) {
      if (expiry > performance.now()) continue
      this.dialogIDs.delete(id)
      this.snapshot.dialogs = this.snapshot.dialogs.filter((d) => d.id !== id)
      expired = true
      void this.child?.answer({ id, cancelled: true }).catch(() => this.ended())
      this.schedulePublish()
    }
    if (expired) this.updatePromptResponseTimeout()
  }
  private recoverStoppedChild(): void {
    this.unresolvedInput = false
    this.snapshot.phase = "interrupted"
    this.snapshot.error = undefined
    this.snapshot.dialogs = []
    this.dialogIDs.clear()
    this.snapshot.pendingMessages = 0
    const notice =
      "Previous work has an unknown outcome. Inspect project changes before sending another instruction."
    this.snapshot.notices = [
      ...this.snapshot.notices.filter((value) => value !== notice).slice(-7),
      notice,
    ]
  }
  private ended(): void {
    this.unresolvedInput = true
    this.snapshot.phase = "interrupted"
    this.snapshot.error = "unknownOutcome"
    if (this.snapshot.selected) {
      this.selected().info.interrupted = true
      void this.saveCatalog().catch(() => {})
    }
    this.publish()
  }
  shutdown(): Promise<void> {
    this.shutdownTask ??= this.finishShutdown()
    return this.shutdownTask
  }
  private async finishShutdown(): Promise<void> {
    this.closing = true
    this.generation += 1
    if (this.publication) clearTimeout(this.publication)
    if (this.dialogTimer) clearInterval(this.dialogTimer)
    await this.child?.shutdown()
    this.child = undefined
    await this.persistence
    this.subscribers.clear()
    this.directories.close()
    this.storage.close()
  }
}
