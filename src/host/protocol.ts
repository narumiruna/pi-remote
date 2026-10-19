import { Buffer } from "node:buffer"

export const MAX_PACKET_BYTES = 4 * 1024 * 1024
export type RemoteFault =
  | "unsupportedVersion"
  | "invalidRequest"
  | "unauthorized"
  | "expired"
  | "conflict"
  | "busy"
  | "unavailable"
  | "permissionDenied"
  | "staleDirectory"
  | "tooLarge"
  | "unknownOutcome"
  | "incompatiblePi"
  | "unsupportedFeature"
  | "storageFailure"
  | "capacity"
  | "cancelled"
  | "providerAuthenticationRequired"
  | "piLaunchFailed"
  | "nodeUnavailable"

export interface SessionInfo {
  id: string
  title: string
  directory: string
  /** Foundation Date: seconds since 2001-01-01T00:00:00Z. */
  updated: number
  interrupted: boolean
}
export interface OutputImageReference {
  id: string
  fault?: RemoteFault
}
export interface TranscriptTool {
  name: string
  target?: string
  status: "running" | "completed" | "failed" | "interrupted"
}
export interface TranscriptMessage {
  id: string
  role: string
  text: string
  thinking?: string
  isError: boolean
  streaming: boolean
  truncated: boolean
  images?: OutputImageReference[]
  tool?: TranscriptTool
  /** Swift Range<Int> encodes as a two-element unkeyed container. */
  toolCallRanges?: [number, number][]
}
export interface ModelOption {
  provider: string
  model: string
  name: string
}
export interface CommandOption {
  name: string
  detail: string
  source: string
}
export interface ExtensionDialog {
  id: string
  method: string
  title: string
  message: string
  options: string[]
  text: string
  expires?: number
}
export interface ExtensionDisplayState {
  statuses: { id: string; text: string }[]
  widgets: { id: string; text: string; placement: "aboveEditor" | "belowEditor" }[]
  notices: { id: string; text: string; severity: "info" | "warning" | "error" }[]
}
export interface RuntimeSettings {
  steeringMode: "all" | "one-at-a-time"
  followUpMode: "all" | "one-at-a-time"
  autoCompactionEnabled: boolean
  acknowledgedAutoRetry?: boolean
}
export interface BashExecution {
  id: string
  command: string
  excludeFromContext: boolean
  status: "running" | "cancelling" | "completed" | "cancelled" | "failed" | "unknownOutcome"
  output: string
  exitCode?: number
  truncated: boolean
  fault?: RemoteFault
}
export interface HostSnapshot {
  host: string
  epoch: string
  sequence: number
  piVersion: string
  capabilities: string[]
  sessions: SessionInfo[]
  selected?: string
  phase: string
  messages: TranscriptMessage[]
  models: ModelOption[]
  model: string
  thinking: string
  thinkingLevels: string[]
  commands: CommandOption[]
  dialogs: ExtensionDialog[]
  notices: string[]
  extensionDisplay?: ExtensionDisplayState
  draft?: string
  draftID?: string
  error?: RemoteFault
  hasOlderMessages: boolean
  runtime?: RuntimeSettings
  pendingMessages?: number
  bash?: BashExecution
}
export function initialSnapshot(host: string, epoch: string): HostSnapshot {
  return {
    host: uuid(host),
    epoch: uuid(epoch),
    sequence: 0,
    piVersion: "Not running",
    capabilities: [
      "directories",
      "directory-path",
      "sessions",
      "prompt",
      "steering",
      "follow-up",
      "stop",
      "models",
      "thinking",
      "extension-dialogs",
      "thinking-display",
      "close-session",
    ],
    sessions: [],
    phase: "idle",
    messages: [],
    models: [],
    model: "",
    thinking: "",
    thinkingLevels: [],
    commands: [],
    dialogs: [],
    notices: [],
    hasOlderMessages: false,
  }
}
export interface DirectoryItem {
  id: string
  name: string
  isDirectory: boolean
  fault?: RemoteFault
}
export interface DirectoryPage {
  id: string
  path: string
  parent?: string
  items: DirectoryItem[]
  next?: string
}
export interface StateSync {
  snapshot?: HostSnapshot
  events: HostSnapshot[]
}
export interface ImageAttachment {
  data: string
  mimeType: string
}
export interface FilePreview {
  name: string
  text: string
  truncated: boolean
  images?: OutputImageReference[]
}
export type ClientPacket =
  | { kind: "pair"; device: string; name: string; grant: Buffer }
  | { kind: "authenticate"; device: string; proof: Buffer }
  | {
      kind: "request"
      id: string
      epoch: string
      session?: string
      action: string
      fields: Record<string, unknown>
    }

/** Error messages never contain packet contents. */
export class ProtocolError extends Error {
  constructor(public readonly code: RemoteFault = "invalidRequest") {
    super(code)
    this.name = "ProtocolError"
  }
}
function invalid(): never {
  throw new ProtocolError()
}
function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return invalid()
  return value as Record<string, unknown>
}
function oneCase(value: unknown): [string, Record<string, unknown>] {
  const entry = Object.entries(object(value))
  if (entry.length !== 1) return invalid()
  const item = entry[0]
  if (!item) return invalid()
  return [item[0], object(item[1])]
}
function string(value: unknown): string {
  if (typeof value !== "string") return invalid()
  return value
}
function bool(value: unknown): boolean {
  if (typeof value !== "boolean") return invalid()
  return value
}
export function uuid(value: unknown): string {
  const text = string(value)
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text))
    return invalid()
  return text.toUpperCase()
}
function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return invalid()
  return value
}
function base64(value: unknown): Buffer {
  const text = string(value)
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text))
    return invalid()
  const bytes = Buffer.from(text, "base64")
  if (bytes.toString("base64") !== text) return invalid()
  return bytes
}
function optional(
  fields: Record<string, unknown>,
  name: string,
  validate: (value: unknown) => unknown,
): void {
  if (fields[name] !== undefined && fields[name] !== null) fields[name] = validate(fields[name])
  else delete fields[name]
}
type Validator = (fields: Record<string, unknown>) => void
const none: Validator = () => {}
const id: Validator = (f) => {
  f.id = uuid(f.id)
}
const cursor: Validator = (f) => {
  optional(f, "cursor", uuid)
}
const data: Validator = (f) => {
  base64(f.data)
}
const directory: Validator = (f) => {
  f.directory = uuid(f.directory)
}
export const SUPPORTED_ACTIONS = [
  "snapshot",
  "synchronize",
  "directories",
  "directoryAtPath",
  "createSession",
  "resumeSession",
  "closeSession",
  "prompt",
  "stop",
  "model",
  "thinking",
  "command",
  "answer",
] as const
export const DEFERRED_ACTIONS = [
  "preview",
  "newSession",
  "importSession",
  "importSessionInDirectory",
  "recoverQueue",
  "bash",
  "abortBash",
  "cycleModel",
  "cycleThinking",
  "compact",
  "rename",
  "history",
  "historyPage",
  "historyEntry",
  "sessionTree",
  "fork",
  "clone",
  "diff",
  "statistics",
  "releaseNotes",
  "exportSession",
  "exportJSONL",
  "outputImage",
  "lastAssistant",
  "runtimeSettings",
  "queueMode",
  "autoCompaction",
  "autoRetry",
  "abortRetry",
] as const
const actions: Record<string, Validator> = {
  snapshot: none,
  synchronize: (f) => {
    optional(f, "epoch", uuid)
    optional(f, "after", integer)
  },
  directories: (f) => {
    optional(f, "id", uuid)
    cursor(f)
  },
  directoryAtPath: (f) => {
    string(f.path)
  },
  createSession: directory,
  resumeSession: id,
  closeSession: none,
  prompt: (f) => {
    string(f.text)
    if (!["prompt", "steer", "followUp"].includes(string(f.delivery))) invalid()
    optional(f, "image", (value) => {
      const image = object(value)
      base64(image.data)
      string(image.mimeType)
      return image
    })
  },
  stop: none,
  model: (f) => {
    string(f.provider)
    string(f.id)
  },
  thinking: (f) => {
    string(f.level)
  },
  command: (f) => {
    string(f.name)
    string(f.arguments)
  },
  answer: (f) => {
    string(f.dialog)
    optional(f, "value", string)
    optional(f, "confirmed", bool)
    bool(f.cancelled)
  },
  preview: id,
  newSession: (f) => {
    bool(f.parent)
  },
  importSession: data,
  importSessionInDirectory: (f) => {
    data(f)
    directory(f)
  },
  recoverQueue: (f) => {
    bool(f.stop)
  },
  bash: (f) => {
    string(f.command)
    bool(f.excludeFromContext)
    bool(f.confirmed)
  },
  abortBash: id,
  cycleModel: none,
  cycleThinking: none,
  compact: (f) => {
    string(f.instructions)
  },
  rename: (f) => {
    string(f.name)
  },
  history: none,
  historyPage: cursor,
  historyEntry: id,
  sessionTree: cursor,
  fork: (f) => {
    string(f.entry)
  },
  clone: none,
  diff: none,
  statistics: none,
  releaseNotes: (f) => {
    integer(f.offset)
    optional(f, "revision", string)
  },
  exportSession: none,
  exportJSONL: none,
  outputImage: id,
  lastAssistant: none,
  runtimeSettings: none,
  queueMode: (f) => {
    if (
      !["steering", "followUp"].includes(string(f.kind)) ||
      !["all", "one-at-a-time"].includes(string(f.mode))
    )
      invalid()
  },
  autoCompaction: (f) => {
    bool(f.enabled)
  },
  autoRetry: (f) => {
    bool(f.enabled)
  },
  abortRetry: none,
}

// Client numbers are integers. Check the original token before JSON.parse can round it.
function checkNumberTokens(text: string): void {
  const tokens = /"(?:[^"\\]|\\.)*"|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g
  for (const match of text.matchAll(tokens)) {
    const token = match[1]
    if (!token) continue
    if (token.length > 128) invalid()
    const parts = /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token)
    if (!parts) invalid()
    const fraction = parts[3] ?? ""
    const scale = Number(parts[4] ?? 0) - fraction.length
    let digits = (parts[2] + fraction).replace(/^0+/, "") || "0"
    if (digits === "0") continue
    if (Math.abs(scale) > 128) invalid()
    if (scale < 0) {
      if (!digits.endsWith("0".repeat(-scale))) invalid()
      digits = digits.slice(0, scale)
    } else {
      digits += "0".repeat(scale)
    }
    if (digits.length > 16 || BigInt(digits || "0") > BigInt(Number.MAX_SAFE_INTEGER)) invalid()
  }
}
// Reject duplicate keys before JSON.parse can discard an enum case or field.
function checkObjectKeys(text: string): void {
  const frames: ({ keys: Set<string>; expectingKey: boolean } | null)[] = []
  const tokens = /"(?:[^"\\]|\\.)*"|[{}[\],:]/g
  for (const match of text.matchAll(tokens)) {
    const token = match[0]
    if (token === "{") frames.push({ keys: new Set(), expectingKey: true })
    else if (token === "[") frames.push(null)
    else if (token === "}" || token === "]") frames.pop()
    else {
      const frame = frames.at(-1)
      if (!frame) continue
      if (token === ",") frame.expectingKey = true
      else if (token === ":") frame.expectingKey = false
      else if (frame.expectingKey) {
        const key: string = JSON.parse(token)
        if (frame.keys.has(key)) invalid()
        frame.keys.add(key)
      }
    }
  }
}
export function decodeClient(data: string | Uint8Array): ClientPacket {
  const bytes = typeof data === "string" ? Buffer.byteLength(data, "utf8") : data.byteLength
  if (bytes > MAX_PACKET_BYTES) throw new ProtocolError("tooLarge")
  let root: Record<string, unknown>
  try {
    const text =
      typeof data === "string" ? data : new TextDecoder("utf-8", { fatal: true }).decode(data)
    checkNumberTokens(text)
    checkObjectKeys(text)
    root = object(JSON.parse(text))
  } catch (error) {
    if (error instanceof ProtocolError) throw error
    return invalid()
  }
  if (root.version !== 1) throw new ProtocolError("unsupportedVersion")
  const [kind, fields] = oneCase(root.payload)
  if (kind === "pair") {
    const grant = base64(fields.grant)
    if (grant.length !== 32) invalid()
    return { kind, device: uuid(fields.device), name: string(fields.name), grant }
  }
  if (kind === "authenticate") {
    const proof = base64(fields.proof)
    if (proof.length !== 32) invalid()
    return { kind, device: uuid(fields.device), proof }
  }
  if (kind !== "request") return invalid()
  const request = object(fields._0)
  const [action, args] = oneCase(request.action)
  if (!Object.hasOwn(actions, action)) return invalid()
  actions[action]?.(args)
  const session =
    request.session === undefined || request.session === null ? undefined : uuid(request.session)
  return {
    kind,
    id: uuid(request.id),
    epoch: uuid(request.epoch),
    ...(session ? { session } : {}),
    action,
    fields: args,
  }
}

/** Swift synthesized enum case with an unlabeled associated value. */
export function enumValue(name: string, value?: unknown): Record<string, unknown> {
  return { [name]: value === undefined ? {} : { _0: value } }
}
export function packet(payload: Record<string, unknown>): string {
  oneCase(payload)
  const result = JSON.stringify({ version: 1, payload }, (key, value: unknown) => {
    if (key === "sequence") integer(value)
    if (
      typeof value === "number" &&
      (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))
    )
      invalid()
    if (typeof value === "bigint") invalid()
    return value
  })
  if (Buffer.byteLength(result, "utf8") > MAX_PACKET_BYTES) throw new ProtocolError("tooLarge")
  return result
}
