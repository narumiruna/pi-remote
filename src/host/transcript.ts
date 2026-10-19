import type { TranscriptMessage } from "./protocol.ts"

export type { TranscriptMessage } from "./protocol.ts"

export const TRANSCRIPT_LIMITS = Object.freeze({
  messages: 200,
  messageBytes: 64 * 1024,
  totalBytes: 2 * 1024 * 1024,
  blocks: 128,
})

type Block = { kind: "text" | "thinking" | "tool"; text: string; name?: string }

/** Reduces Pi events to bounded, text-only app messages. Images and opaque signatures are not retained. */
export class TranscriptReducer {
  private items: TranscriptMessage[] = []
  private open = new Map<string, string>()
  private tools = new Map<string, string>()
  private blocks = new Map<number, Block>()
  private assistant?: string
  private liveTruncated = false
  private historyOmitted = false

  get omitted(): boolean {
    return this.historyOmitted
  }

  get messages(): TranscriptMessage[] {
    return this.items.map((message) => ({ ...message }))
  }

  clear(): void {
    this.items = []
    this.open.clear()
    this.tools.clear()
    this.blocks.clear()
    this.assistant = undefined
    this.liveTruncated = false
    this.historyOmitted = false
  }

  replaceHistory(messages: unknown[]): void {
    this.clear()
    this.historyOmitted = messages.length > TRANSCRIPT_LIMITS.messages
    for (const message of messages.slice(-TRANSCRIPT_LIMITS.messages)) {
      if (isRecord(message)) this.finishMessage(message, false)
    }
    this.open.clear()
    this.assistant = undefined
    this.blocks.clear()
  }

  consume(event: Record<string, unknown>): void {
    switch (event.type) {
      case "message_start":
        if (isRecord(event.message)) this.startMessage(event.message)
        break
      case "message_update":
        if (isRecord(event.assistantMessageEvent)) this.updateAssistant(event.assistantMessageEvent)
        break
      case "message_end":
        if (isRecord(event.message)) this.finishMessage(event.message, false)
        break
      case "tool_execution_start":
      case "tool_execution_update":
      case "tool_execution_end":
        this.updateTool(event)
        break
      case "agent_settled":
        for (const item of this.items) {
          if (item.streaming && event.aborted === true && item.role === "tool") {
            item.text = boundedText(
              `${item.text}\nExecution interrupted; outcome is unconfirmed.`,
            ).text
            item.isError = true
          }
          if (item.tool && item.streaming && event.aborted === true)
            item.tool.status = "interrupted"
          item.streaming = false
        }
        this.open.clear()
        this.blocks.clear()
        this.assistant = undefined
        break
    }
    this.bound()
  }

  private startMessage(message: Record<string, unknown>): void {
    const role = message.role
    if (role === "assistant") {
      this.assistant = undefined
      this.blocks.clear()
      this.liveTruncated = false
    }
    this.finishMessage(message, true)
    if (role === "assistant") {
      this.assistant = this.open.get("assistant")
      if (Array.isArray(message.content)) {
        for (const [index, content] of message.content
          .slice(0, TRANSCRIPT_LIMITS.blocks)
          .entries()) {
          if (!isRecord(content)) continue
          if (content.type === "text" || content.type === "thinking") {
            const text = boundedText(content.type === "text" ? content.text : content.thinking)
            this.blocks.set(index, { kind: content.type, text: text.text })
            this.liveTruncated ||= text.truncated
          } else if (content.type === "toolCall") {
            const args = boundedJSON(content.arguments)
            this.blocks.set(index, {
              kind: "tool",
              name: string(content.name),
              text: args.text,
            })
            this.liveTruncated ||= args.truncated
          }
        }
        this.boundBlocks()
      }
    }
  }

  private finishMessage(message: Record<string, unknown>, streaming: boolean): void {
    const role = message.role
    if (role === "system" || (role === "custom" && message.display === false)) return
    if (
      ![
        "user",
        "assistant",
        "toolResult",
        "bashExecution",
        "custom",
        "branchSummary",
        "compactionSummary",
      ].includes(string(role))
    )
      return
    const toolId = role === "toolResult" ? string(message.toolCallId) : ""
    const existing = toolId ? this.tools.get(toolId) : this.open.get(string(role))
    const prior = this.items.find((item) => item.id === existing)
    const content = readContent(message.content)
    let text = content.text
    let isError = message.isError === true || message.stopReason === "error"
    if (role === "toolResult") text = toolText(message.toolName, text)
    if (role === "branchSummary" || role === "compactionSummary") text = string(message.summary)
    if (role === "bashExecution") {
      text = toolText("bash", `${string(message.command)}\n${string(message.output)}`)
      isError =
        message.cancelled === true ||
        (typeof message.exitCode === "number" && message.exitCode !== 0)
    }
    if (role === "assistant" && (isError || message.stopReason === "aborted")) {
      text += `${text ? "\n" : ""}${string(message.errorMessage) || (isError ? "Assistant response failed." : "Assistant response interrupted.")}`
    }
    const bounded = boundedText(text)
    const thinking = boundedText(
      content.thinking,
      Math.max(0, TRANSCRIPT_LIMITS.messageBytes - byteLength(bounded.text)),
    )
    const item: TranscriptMessage = {
      id: prior?.id ?? crypto.randomUUID(),
      role:
        role === "toolResult" || role === "bashExecution"
          ? "tool"
          : role === "custom"
            ? "assistant"
            : string(role),
      text: bounded.text,
      ...(thinking.text ? { thinking: thinking.text } : {}),
      isError,
      streaming,
      truncated:
        content.truncated || bounded.truncated || thinking.truncated || message.truncated === true,
    }
    if (role === "toolResult" || role === "bashExecution") {
      item.tool = {
        name: boundedText(role === "bashExecution" ? "bash" : message.toolName, 128).text,
        status: streaming ? "running" : isError ? "failed" : "completed",
        ...(prior?.tool?.target ? { target: prior.tool.target } : {}),
      }
    }
    if (prior) this.items[this.items.indexOf(prior)] = item
    else this.items.push(item)
    if (toolId) this.tools.set(toolId, item.id)
    if (streaming) this.open.set(string(role), item.id)
    else this.open.delete(string(role))
    if (role === "assistant" && !streaming) {
      this.assistant = undefined
      this.blocks.clear()
    }
    this.bound()
  }

  private updateAssistant(event: Record<string, unknown>): void {
    const type = string(event.type)
    if (
      (type === "done" || type === "error") &&
      isRecord(type === "done" ? event.message : event.error)
    ) {
      this.finishMessage(
        (type === "done" ? event.message : event.error) as Record<string, unknown>,
        false,
      )
      return
    }
    const index = event.contentIndex
    if (
      !Number.isInteger(index) ||
      typeof index !== "number" ||
      index < 0 ||
      index >= TRANSCRIPT_LIMITS.blocks
    ) {
      if (typeof index === "number") this.liveTruncated = true
      return
    }
    if (!this.assistant) this.startMessage({ role: "assistant", content: [] })
    const item = this.items.find((message) => message.id === this.assistant)
    if (!item) return
    let block = this.blocks.get(index)
    if (type.startsWith("text_") || type.startsWith("thinking_")) {
      const kind = type.startsWith("text_") ? "text" : "thinking"
      block ??= { kind, text: "" }
      block.kind = kind
      if (type.endsWith("_delta")) block.text += string(event.delta)
      if (type.endsWith("_end")) block.text = string(event.content)
    } else if (type.startsWith("toolcall_")) {
      block ??= { kind: "tool", text: "", name: string(event.toolName) }
      if (type === "toolcall_start") block.name = string(event.toolName)
      if (type === "toolcall_delta") block.text += string(event.delta)
      if (type === "toolcall_end" && isRecord(event.toolCall)) {
        const args = boundedJSON(event.toolCall.arguments)
        block.name = string(event.toolCall.name)
        block.text = args.text
        this.liveTruncated ||= args.truncated
      }
    }
    if (!block) return
    this.blocks.set(index, block)
    this.boundBlocks()
    const values = [...this.blocks.entries()]
      .sort(([left], [right]) => left - right)
      .map(([, value]) => value)
    const text = boundedText(
      values
        .filter((value) => value.kind !== "thinking")
        .map(renderBlock)
        .join("\n"),
    )
    const thinking = boundedText(
      values
        .filter((value) => value.kind === "thinking")
        .map((value) => value.text)
        .join("\n"),
      Math.max(0, TRANSCRIPT_LIMITS.messageBytes - byteLength(text.text)),
    )
    item.text = text.text
    if (thinking.text) item.thinking = thinking.text
    else delete item.thinking
    item.truncated = this.liveTruncated || text.truncated || thinking.truncated
  }

  private boundBlocks(): void {
    let remaining = TRANSCRIPT_LIMITS.messageBytes
    for (const block of this.blocks.values()) {
      const text = boundedText(block.text, remaining)
      block.text = text.text
      remaining -= byteLength(text.text)
      this.liveTruncated ||= text.truncated
      if (block.name) block.name = boundedText(block.name, 256).text
    }
  }

  private updateTool(event: Record<string, unknown>): void {
    if (typeof event.toolCallId !== "string") return
    const id = this.tools.get(event.toolCallId)
    let item = this.items.find((message) => message.id === id)
    if (!item) {
      item = {
        id: crypto.randomUUID(),
        role: "tool",
        text: toolText(event.toolName, ""),
        isError: false,
        streaming: true,
        truncated: false,
      }
      this.items.push(item)
      this.tools.set(event.toolCallId, item.id)
    }
    const ending = event.type === "tool_execution_end"
    const args = isRecord(event.args) ? event.args : {}
    const target =
      typeof args.path === "string" ? boundedText(args.path, 256).text : item.tool?.target
    item.tool = {
      name: boundedText(event.toolName, 128).text,
      status: ending ? (event.isError === true ? "failed" : "completed") : "running",
      ...(target ? { target } : {}),
    }
    const result = ending ? event.result : event.partialResult
    if (isRecord(result)) {
      const content = readContent(result.content)
      const text = boundedText(toolText(event.toolName, content.text))
      item.text = text.text
      item.truncated = content.truncated || text.truncated
    } else if (event.type === "tool_execution_start") {
      const args = boundedJSON(event.args)
      const text = boundedText(toolText(event.toolName, args.text))
      item.text = text.text
      item.truncated = args.truncated || text.truncated
    }
    if (ending) {
      item.streaming = false
      item.isError = event.isError === true
      if (item.isError && !isRecord(result))
        item.text = toolText(event.toolName, "Tool execution failed.")
    }
  }

  private bound(): void {
    let total = this.items.reduce(
      (sum, item) => sum + byteLength(item.text) + byteLength(item.thinking ?? ""),
      0,
    )
    while (this.items.length > TRANSCRIPT_LIMITS.messages || total > TRANSCRIPT_LIMITS.totalBytes) {
      const removed = this.items.shift()
      if (!removed) break
      this.historyOmitted = true
      total -= byteLength(removed.text) + byteLength(removed.thinking ?? "")
    }
    const retained = new Set(this.items.map((item) => item.id))
    for (const [key, id] of this.tools) if (!retained.has(id)) this.tools.delete(key)
    for (const [key, id] of this.open) if (!retained.has(id)) this.open.delete(key)
    if (this.assistant && !retained.has(this.assistant)) this.assistant = undefined
  }
}

function readContent(content: unknown): { text: string; thinking: string; truncated: boolean } {
  if (typeof content === "string") return { ...boundedText(content), thinking: "" }
  if (!Array.isArray(content)) return { text: "", thinking: "", truncated: false }
  const text: string[] = []
  const thinking: string[] = []
  let remaining = TRANSCRIPT_LIMITS.messageBytes
  let truncated = false
  for (const block of content) {
    if (!isRecord(block)) continue
    let value = ""
    if (block.type === "text") value = string(block.text)
    else if (block.type === "thinking") value = string(block.thinking)
    else if (block.type === "toolCall") {
      const args = boundedJSON(block.arguments)
      value = toolText(block.name, args.text)
      truncated ||= args.truncated
    } else if (block.type === "image") value = "[Image omitted]"
    // Image data and provider signatures are deliberately omitted.
    const clipped = boundedText(value, Math.max(0, remaining - 1))
    remaining -= byteLength(clipped.text) + (clipped.text ? 1 : 0)
    truncated ||= clipped.truncated
    if (clipped.text) (block.type === "thinking" ? thinking : text).push(clipped.text)
  }
  return { text: text.join("\n"), thinking: thinking.join("\n"), truncated }
}

function renderBlock(block: Block): string {
  return block.kind === "tool" ? toolText(block.name, block.text) : block.text
}

function toolText(name: unknown, text: string): string {
  return `${boundedText(string(name) || "tool", 256).text}${text ? `\n${text}` : ""}`
}

function boundedJSON(value: unknown): { text: string; truncated: boolean } {
  try {
    return boundedText(JSON.stringify(value) ?? "", 4096)
  } catch {
    return { text: "[Arguments unavailable]", truncated: true }
  }
}

function boundedText(
  value: unknown,
  limit: number = TRANSCRIPT_LIMITS.messageBytes,
): { text: string; truncated: boolean } {
  // Remove terminal escape sequences and non-display controls, but keep tab and newline.
  // biome-ignore lint/suspicious/noControlCharactersInRegex: Match terminal controls to remove them.
  const osc = /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g
  // biome-ignore lint/suspicious/noControlCharactersInRegex: Match terminal controls to remove them.
  const csi = /\x1b\[[0-?]*[ -/]*[@-~]/g
  // biome-ignore lint/suspicious/noControlCharactersInRegex: Match non-display controls to remove them.
  const controls = /[\x00-\x08\x0b-\x1f\x7f-\x9f]/g
  const text = string(value).replace(osc, "").replace(csi, "").replace(controls, "")
  const bytes = Buffer.from(text)
  if (bytes.length <= limit) return { text, truncated: false }
  let end = Math.max(0, limit)
  while (end > 0 && ((bytes[end] ?? 0) & 0xc0) === 0x80) end--
  return { text: bytes.subarray(0, end).toString("utf8"), truncated: true }
}

function byteLength(value: string): number {
  return Buffer.byteLength(value)
}
function string(value: unknown): string {
  return typeof value === "string" ? value : ""
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
