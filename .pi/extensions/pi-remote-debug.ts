import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, parse, resolve } from "node:path";
import { TextDecoder } from "node:util";
import { inflateSync } from "node:zlib";

const MAX_RECORD = 4096;
const MAX_RESPONSE = 3 * 1024 * 1024;
const MAX_PNG = 2 * 1024 * 1024;
const TIMEOUT_MS = 5000;
const modes = ["pi", "desktop"];
const destinations = ["conversation", "overview", "workspace", "session", "settings", "devices", "none"];
const phases = ["starting", "idle", "working", "queued", "bash", "waiting", "stopping", "retrying", "compacting", "recovering", "unavailable", "interrupted", "unknown"];
const methods = ["appkit-view"];
type Operation = "status" | "capture" | "interact";
const interactionValues = {
  navigate: ["conversation", "overview", "settings", "devices"],
  interface_mode: ["pi", "desktop"],
  sidebar: ["show", "hide"],
  inspector: ["Files", "Session", "Activity", "hide"],
  panel: ["commands", "resume", "palette", "hotkeys", "directory", "workspace", "close"],
  type_text: [],
  focus_editor: ["editor"],
  scroll: ["history_up", "history_down", "history_top", "history_bottom", "dock_up", "dock_down", "page_up", "page_down"],
} satisfies Record<string, string[]>;
type InteractionAction = keyof typeof interactionValues;
type Interaction = { action: InteractionAction; value: string };
const interactionActions = Object.keys(interactionValues);
type RecordValue = Record<string, unknown>;

// Only these fixed messages can leave the client. Never include an OS error,
// parser error, server text, discovery data, or capability token in a result.
const errors = {
  unavailable: "Pi Remote debug is unavailable. Enable debug mode in the Mac app Settings.",
  unsafe_endpoint: "Pi Remote debug endpoint permissions or paths are unsafe.",
  invalid_response: "Pi Remote debug returned an invalid response.",
  timeout: "Pi Remote debug timed out after 5 seconds. No request was retried.",
  cancelled: "Pi Remote debug request was cancelled.",
  operation_failed: "Pi Remote debug operation failed.",
  disabled: "Pi Remote debug mode is disabled.",
  window_unavailable: "The Pi Remote window is unavailable. Show the main window and try again.",
  window_ambiguous: "The Pi Remote window selection is ambiguous.",
  capture_protected: "Capture is blocked while a protected surface is visible.",
  capture_failed: "Pi Remote window capture failed.",
  capture_too_large: "Pi Remote window capture exceeds the image limit.",
  capture_busy: "Pi Remote window capture is busy.",
  interaction_blocked: "Pi Remote debug interaction is blocked while a protected surface is visible.",
  invalid_interaction: "Pi Remote debug interaction is invalid or exceeds its size limit.",
  target_unavailable: "Pi Remote debug interaction target is unavailable.",
  unsupported_operation: "Pi Remote debug operation is unsupported.",
} as const;
class DebugError extends Error {
  constructor(code: keyof typeof errors, operation?: Operation) {
    const uncertain = operation === "interact" && (code === "timeout" || code === "cancelled");
    super(errors[code] + (uncertain ? " The interaction may already apply. Inspect the app before retrying. No automatic retry was made." : ""));
  }
}
function invalid(): never { throw new DebugError("invalid_response"); }
function object(value: unknown): RecordValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) invalid();
  return value as RecordValue;
}
function exact(value: unknown, keys: string[]): RecordValue {
  const record = object(value);
  if (Object.keys(record).length !== keys.length || keys.some(key => !Object.hasOwn(record, key))) invalid();
  return record;
}
function integer(value: unknown, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) invalid();
  return value;
}
function enumeration(value: unknown, values: string[]): string {
  if (typeof value !== "string" || !values.includes(value)) invalid();
  return value;
}
function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") invalid();
  return value;
}

const statusProperties = {
  interfaceMode: { type: "string", enum: modes },
  destination: { type: "string", enum: destinations },
  windowWidth: { type: "integer", minimum: 0, maximum: 16384 },
  windowHeight: { type: "integer", minimum: 0, maximum: 16384 },
  sessionPresent: { type: "boolean" },
  phase: { type: "string", enum: phases },
  listenerOn: { type: "boolean" },
  sessionCount: { type: "integer", minimum: 0, maximum: 10000 },
  messageCount: { type: "integer", minimum: 0, maximum: 10000 },
  dialogCount: { type: "integer", minimum: 0, maximum: 10000 },
};
function schema(properties: RecordValue) {
  return { type: "object", properties, required: Object.keys(properties), additionalProperties: false };
}
export function validateStatus(value: unknown) {
  const r = exact(value, Object.keys(statusProperties));
  return {
    interfaceMode: enumeration(r.interfaceMode, modes), destination: enumeration(r.destination, destinations),
    windowWidth: integer(r.windowWidth, 0, 16384), windowHeight: integer(r.windowHeight, 0, 16384),
    sessionPresent: boolean(r.sessionPresent), phase: enumeration(r.phase, phases), listenerOn: boolean(r.listenerOn),
    sessionCount: integer(r.sessionCount, 0, 10000), messageCount: integer(r.messageCount, 0, 10000),
    dialogCount: integer(r.dialogCount, 0, 10000),
  };
}

export function validateInteraction(value: unknown): Interaction {
  try {
    const r = exact(value, ["action", "value"]);
    const action = enumeration(r.action, interactionActions) as InteractionAction;
    if (typeof r.value !== "string") invalid();
    if (action === "type_text") {
      if (!r.value.length || r.value.includes("\0") || Buffer.byteLength(r.value, "utf8") > 2048) invalid();
    } else if (!(interactionValues[action] as string[]).includes(r.value)) invalid();
    return { action, value: r.value };
  } catch { throw new DebugError("invalid_interaction"); }
}
export function validateInteractionResult(value: unknown, expectedAction?: InteractionAction) {
  const r = exact(value, ["action", "outcome"]);
  const action = enumeration(r.action, interactionActions) as InteractionAction;
  if ((expectedAction !== undefined && action !== expectedAction) || r.outcome !== "applied") invalid();
  return { action, outcome: "applied" as const };
}

function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// Check PNG framing, CRCs, dimensions, and bounded decoded scanlines. This also
// rejects compressed data that expands past the declared pixel dimensions.
function validatePNG(png: Buffer, width: number, height: number) {
  if (png.length < 57 || !png.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))) invalid();
  let offset = 8;
  let header: Buffer | undefined;
  let ended = false;
  let palette = false;
  let dataEnded = false;
  const data: Buffer[] = [];
  while (offset < png.length) {
    if (offset + 12 > png.length) invalid();
    const length = png.readUInt32BE(offset);
    if (length > png.length - offset - 12) invalid();
    const type = png.toString("latin1", offset + 4, offset + 8);
    if (!/^[A-Za-z]{4}$/.test(type)) invalid();
    const payload = png.subarray(offset + 8, offset + 8 + length);
    if (crc32(png.subarray(offset + 4, offset + 8 + length)) !== png.readUInt32BE(offset + 8 + length)) invalid();
    if (!header && type !== "IHDR") invalid();
    if (type === "IHDR") {
      if (header || length !== 13) invalid();
      header = payload;
    } else if (type === "PLTE") {
      if (palette || data.length || !length || length % 3 || length > 768) invalid();
      palette = true;
    } else if (type === "IDAT") {
      if (dataEnded) invalid();
      data.push(payload);
    } else if (type === "IEND") {
      if (length || !data.length || offset + 12 !== png.length) invalid();
      ended = true;
    } else {
      // Reject unknown critical chunks and animated PNGs.
      if (type[0] === type[0].toUpperCase() || ["acTL", "fcTL", "fdAT"].includes(type)) invalid();
      if (data.length) dataEnded = true;
    }
    offset += length + 12;
  }
  if (!header || !ended || header.readUInt32BE(0) !== width || header.readUInt32BE(4) !== height) invalid();
  const depth = header[8], color = header[9], interlace = header[12];
  const channels = ({ 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 } as Record<number, number>)[color];
  const depths = color === 0 ? [1, 2, 4, 8, 16] : color === 3 ? [1, 2, 4, 8] : [8, 16];
  if (!channels || !depths.includes(depth) || header[10] || header[11] || interlace > 1 || (color === 3 && !palette)) invalid();
  const passes = interlace === 0 ? [[0, 0, 1, 1]] : [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]];
  const rows: { bytes: number; count: number }[] = [];
  let expected = 0;
  for (const [x, y, dx, dy] of passes) {
    const w = Math.max(0, Math.ceil((width - x) / dx)), h = Math.max(0, Math.ceil((height - y) / dy));
    if (!w || !h) continue;
    const bytes = Math.ceil(w * channels * depth / 8) + 1;
    rows.push({ bytes, count: h });
    expected += bytes * h;
  }
  let decoded: Buffer;
  try { decoded = inflateSync(Buffer.concat(data), { maxOutputLength: expected + 1 }); } catch { invalid(); }
  if (decoded.length !== expected) invalid();
  let rowOffset = 0;
  for (const row of rows) for (let y = 0; y < row.count; y++) {
    if (decoded[rowOffset] > 4) invalid();
    rowOffset += row.bytes;
  }
}

export function validateCapture(value: unknown) {
  const r = exact(value, ["png", "width", "height", "capturedAt", "method"]);
  const width = integer(r.width, 1, 1920), height = integer(r.height, 1, 1920);
  if (width * height > 2304000) invalid();
  if (typeof r.capturedAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(r.capturedAt) || !Number.isFinite(Date.parse(r.capturedAt))) invalid();
  const normalizedTime = r.capturedAt.replace(/(?:\.(\d{1,3}))?Z$/, (_match, fraction) => `.${(fraction ?? "").padEnd(3, "0")}Z`);
  if (new Date(r.capturedAt).toISOString() !== normalizedTime) invalid();
  const method = enumeration(r.method, methods);
  if (typeof r.png !== "string" || r.png.length > 4 * Math.ceil(MAX_PNG / 3) || r.png.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(r.png)) invalid();
  const png = Buffer.from(r.png, "base64");
  if (png.length > MAX_PNG || png.toString("base64") !== r.png) invalid();
  validatePNG(png, width, height);
  return { image: { type: "image" as const, data: r.png, mimeType: "image/png" }, metadata: { width, height, capturedAt: r.capturedAt, method } };
}

function parseJSON(bytes: Buffer): unknown {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); } catch { invalid(); }
}
export function validateResponse(bytes: Buffer, id: string, operation: Operation, expectedAction?: InteractionAction) {
  const r = object(parseJSON(bytes));
  if (r.version !== 1 || r.id !== id || typeof r.ok !== "boolean") invalid();
  if (!r.ok) {
    exact(r, ["version", "id", "ok", "error"]);
    const code = typeof r.error === "string" && Object.hasOwn(errors, r.error) ? r.error as keyof typeof errors : "operation_failed";
    throw new DebugError(code, operation);
  }
  exact(r, ["version", "id", "ok", "result"]);
  if (operation === "interact") return validateInteractionResult(r.result, expectedAction);
  return operation === "status" ? validateStatus(r.result) : validateCapture(r.result);
}

async function discover(directory: string) {
  const unsafe = (): never => { throw new DebugError("unsafe_endpoint"); };
  const uid = process.getuid?.();
  if (uid === undefined || !isAbsolute(directory) || resolve(directory) !== directory) unsafe();
  // Inspect every ancestor, not only the final private directory. Root-owned
  // sticky system directories are allowed; other writable shared parents and
  // all symlinks are rejected.
  const parents: string[] = [];
  for (let path = directory; ; path = dirname(path)) {
    parents.push(path);
    if (path === parse(path).root) break;
  }
  for (const path of parents.reverse()) {
    const stat = await lstat(path);
    const stickySystemDirectory = stat.uid === 0 && (stat.mode & 0o1000) !== 0;
    if (!stat.isDirectory() || ![0, uid].includes(stat.uid) || ((stat.mode & 0o022) && !stickySystemDirectory)) unsafe();
    if (path === directory && (stat.uid !== uid || (stat.mode & 0o7777) !== 0o700)) unsafe();
  }
  const endpointPath = join(directory, "endpoint.json");
  const before = await lstat(endpointPath);
  const privateFile = (stat: typeof before) => stat.isFile() && stat.uid === uid && (stat.mode & 0o7777) === 0o600 && stat.nlink === 1 && stat.size <= MAX_RECORD;
  if (!privateFile(before)) unsafe();
  const file = await open(endpointPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  let bytes: Buffer;
  try {
    const stat = await file.stat();
    if (!privateFile(stat) || stat.dev !== before.dev || stat.ino !== before.ino) unsafe();
    const buffer = Buffer.alloc(MAX_RECORD + 1);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > MAX_RECORD) unsafe();
    bytes = buffer.subarray(0, bytesRead);
  } finally { await file.close(); }
  let endpoint: RecordValue;
  try { endpoint = exact(parseJSON(bytes), ["version", "socketPath", "token"]); } catch { unsafe(); }
  if (endpoint.version !== 1 || endpoint.socketPath !== join(directory, "control.sock") || typeof endpoint.token !== "string" || !/^[a-fA-F0-9]{64}$/.test(endpoint.token)) unsafe();
  const socket = await lstat(endpoint.socketPath as string);
  if (!socket.isSocket() || socket.uid !== uid || (socket.mode & 0o7777) !== 0o600) unsafe();
  return { socketPath: endpoint.socketPath as string, token: endpoint.token as string };
}

// Each instance owns only its in-flight calls. No connections, timers, or file
// reads occur at construction or extension registration.
export class DebugClient {
  private readonly pending = new Set<() => void>();
  private disposed = false;
  private readonly directory: string;
  constructor(directory = join(homedir(), "Library", "Caches", "PiRemoteDebug")) { this.directory = directory; }

  close() {
    this.disposed = true;
    for (const cancel of [...this.pending]) cancel();
  }

  request(operation: Operation, signal?: AbortSignal, interaction?: Interaction): Promise<ReturnType<typeof validateResponse>> {
    if (this.disposed || signal?.aborted) return Promise.reject(new DebugError("cancelled", operation));
    let validatedInteraction: Interaction | undefined;
    try {
      if (!["status", "capture", "interact"].includes(operation)) throw new DebugError("unsupported_operation");
      if (operation === "interact") validatedInteraction = validateInteraction(interaction);
      else if (interaction !== undefined) throw new DebugError("invalid_interaction");
    } catch (error) { return Promise.reject(error); }
    return new Promise((resolveResult, reject) => {
      let done = false;
      let socket: Socket | undefined;
      const finish = (error?: DebugError, result?: ReturnType<typeof validateResponse>) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal?.removeEventListener("abort", cancel);
        this.pending.delete(cancel);
        socket?.removeAllListeners();
        socket?.destroy();
        if (error) reject(error); else resolveResult(result!);
      };
      const cancel = () => finish(new DebugError("cancelled", operation));
      const timer = setTimeout(() => finish(new DebugError("timeout", operation)), TIMEOUT_MS);
      this.pending.add(cancel);
      signal?.addEventListener("abort", cancel, { once: true });
      void (async () => {
        try {
          const endpoint = await discover(this.directory);
          if (done) return;
          const id = randomUUID();
          const request = Buffer.from(JSON.stringify({ version: 1, id, token: endpoint.token, operation, ...(validatedInteraction ? { interaction: validatedInteraction } : {}) }) + "\n");
          if (request.length > MAX_RECORD) throw new DebugError(operation === "interact" ? "invalid_interaction" : "unsafe_endpoint");
          socket = new Socket();
          const chunks: Buffer[] = [];
          let size = 0;
          let receivedLine = false;
          socket.on("error", () => finish(new DebugError("unavailable")));
          socket.on("close", () => finish(new DebugError("invalid_response")));
          socket.on("data", (chunk: Buffer) => {
            size += chunk.length;
            if (size > MAX_RESPONSE || receivedLine) { finish(new DebugError("invalid_response")); return; }
            chunks.push(chunk);
            const newline = chunk.indexOf(10);
            if (newline === -1) return;
            if (newline !== chunk.length - 1) { finish(new DebugError("invalid_response")); return; }
            receivedLine = true;
          });
          // The server closes after its single response. Wait for EOF so a
          // second record cannot bypass validation by arriving in another chunk.
          socket.on("end", () => {
            if (!receivedLine) { finish(new DebugError("invalid_response")); return; }
            try { finish(undefined, validateResponse(Buffer.concat(chunks, size).subarray(0, -1), id, operation, validatedInteraction?.action)); }
            catch (error) { finish(error instanceof DebugError ? error : new DebugError("invalid_response")); }
          });
          socket.connect(endpoint.socketPath, () => socket?.write(request));
        } catch (error) { finish(error instanceof DebugError ? error : new DebugError("unavailable")); }
      })();
    });
  }
}

const metadataSchema = schema({
  width: { type: "integer", minimum: 1, maximum: 1920 }, height: { type: "integer", minimum: 1, maximum: 1920 },
  capturedAt: { type: "string" }, method: { type: "string", enum: methods },
});
export default function (pi: ExtensionAPI) {
  let client = new DebugClient();
  pi.on("session_shutdown", () => client.close());
  pi.on("session_start", () => { client.close(); client = new DebugClient(); });
  pi.registerTool({
    name: "pi_remote_debug_status", label: "Pi Remote debug status",
    description: "Read bounded, sanitized Pi Remote Mac app state. Requires opt-in debug mode in Mac Settings. Does not change app or session state.",
    parameters: schema({}), outputSchema: schema(statusProperties),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async execute(_id, _params, signal) {
      const status = await client.request("status", signal) as ReturnType<typeof validateStatus>;
      return { content: [{ type: "text", text: JSON.stringify(status) }], details: status, structuredContent: status };
    },
  });
  pi.registerTool({
    name: "pi_remote_debug_capture", label: "Pi Remote window capture",
    description: "Capture only the current Pi Remote Mac app window after debug-mode opt-in. Pixels can contain private content and can enter saved history and model requests. AppKit view captures can omit window chrome or composited content. No desktop fallback. Returns image and metadata; codemode callers use image(result.image).",
    parameters: schema({}),
    outputSchema: schema({ image: schema({ type: { const: "image", type: "string" }, data: { type: "string" }, mimeType: { const: "image/png", type: "string" } }), metadata: metadataSchema }),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    async execute(_id, _params, signal) {
      const capture = await client.request("capture", signal) as ReturnType<typeof validateCapture>;
      return { content: [{ type: "text", text: JSON.stringify(capture.metadata) }, capture.image], details: capture.metadata, structuredContent: capture };
    },
  });
  pi.registerTool({
    name: "pi_remote_debug_interact", label: "Pi Remote debug interaction",
    description: "Use app-only semantic controls in the opted-in Pi Remote Mac app, not physical keyboard, pointer or desktop input. Protected surfaces (pairing, extension requests, modal dialogs and ambiguous windows) block interaction. Never submits prompts, executes commands, starts/stops Pi or networking, answers dialogs, changes credentials or controls another app. navigate: conversation|overview|settings|devices; interface_mode: pi|desktop; sidebar: show|hide; inspector: Files|Session|Activity|hide; panel: commands|resume|palette|hotkeys|directory|workspace|close (ordinary panels only); type_text: append nonempty text, at most 2048 UTF-8 bytes, without replacing the draft; focus_editor: editor; scroll: history_up|history_down|history_top|history_bottom|dock_up|dock_down|page_up|page_down. The full encoded request must fit 4096 bytes. Text enters Pi tool-call history, but is never echoed in results. No automatic retries. After timeout or cancellation the interaction may already apply; inspect status/capture before retrying.",
    parameters: schema({ action: { type: "string", enum: interactionActions }, value: { type: "string", minLength: 1, maxLength: 2048 } }),
    outputSchema: schema({ action: { type: "string", enum: interactionActions }, outcome: { type: "string", const: "applied" } }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    async execute(_id, params, signal) {
      const result = await client.request("interact", signal, params as Interaction) as ReturnType<typeof validateInteractionResult>;
      return { content: [{ type: "text", text: JSON.stringify(result) }], details: result, structuredContent: result };
    },
  });
}
