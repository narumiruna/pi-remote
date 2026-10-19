import { describe, expect, test } from "bun:test"
import { TRANSCRIPT_LIMITS, TranscriptReducer } from "./transcript.ts"

const start = (reducer: TranscriptReducer) =>
  reducer.consume({ type: "message_start", message: { role: "assistant", content: [] } })
const update = (
  reducer: TranscriptReducer,
  type: string,
  contentIndex: number,
  fields: Record<string, unknown>,
) =>
  reducer.consume({
    type: "message_update",
    assistantMessageEvent: { type, contentIndex, ...fields },
  })
const end = (reducer: TranscriptReducer, message: Record<string, unknown>) =>
  reducer.consume({ type: "message_end", message })

describe("Pi transcript reducer", () => {
  test("deduplicates user start/end while preserving UUID message identity", () => {
    const reducer = new TranscriptReducer()
    const message = { role: "user", content: "hello", timestamp: 1 }
    reducer.consume({ type: "message_start", message })
    const id = reducer.messages[0]?.id
    end(reducer, message)
    expect(reducer.messages).toHaveLength(1)
    expect(reducer.messages[0]).toMatchObject({ id, role: "user", text: "hello", streaming: false })
    expect(id).toMatch(/^[0-9a-f-]{36}$/i)
  })

  test("accumulates by contentIndex and replaces partial blocks and final messages", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    const id = reducer.messages[0]?.id
    update(reducer, "text_delta", 2, { delta: "second" })
    update(reducer, "thinking_delta", 0, { delta: "private thinking" })
    update(reducer, "text_delta", 1, { delta: "fir" })
    update(reducer, "text_delta", 1, { delta: "st" })
    expect(reducer.messages[0]).toMatchObject({
      text: "first\nsecond",
      thinking: "private thinking",
      streaming: true,
    })
    update(reducer, "text_end", 1, { content: "corrected" })
    update(reducer, "thinking_end", 0, { content: "final thinking" })
    expect(reducer.messages[0]).toMatchObject({
      text: "corrected\nsecond",
      thinking: "final thinking",
    })
    end(reducer, {
      role: "assistant",
      content: [{ type: "text", text: "authoritative" }],
      stopReason: "stop",
    })
    expect(reducer.messages).toHaveLength(1)
    expect(reducer.messages[0]).toMatchObject({
      id,
      text: "authoritative",
      streaming: false,
      isError: false,
    })
    expect(reducer.messages[0]?.thinking).toBeUndefined()
  })

  test("agent_end cannot end streaming before agent_settled", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    reducer.consume({ type: "agent_end", messages: [], willRetry: true })
    expect(reducer.messages[0]?.streaming).toBe(true)
    reducer.consume({ type: "agent_settled", aborted: false })
    expect(reducer.messages[0]?.streaming).toBe(false)
  })

  test("renders streamed and final generic tool calls without provider metadata", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    update(reducer, "toolcall_start", 0, { id: "call-1", toolName: "read" })
    update(reducer, "toolcall_delta", 0, { delta: '{"path":"draft' })
    expect(reducer.messages[0]?.text).toContain("read")
    update(reducer, "toolcall_end", 0, {
      toolCall: { id: "call-1", name: "read", arguments: { path: "final.ts" } },
    })
    expect(reducer.messages[0]?.text).toContain('"path":"final.ts"')
    end(reducer, {
      role: "assistant",
      content: [
        {
          type: "toolCall",
          name: "read",
          arguments: { path: "final.ts" },
          thoughtSignature: "SECRET",
        },
      ],
      stopReason: "toolUse",
    })
    expect(JSON.stringify(reducer.messages)).not.toContain("SECRET")
  })

  test("tool partial results replace previous results and final tool messages do not duplicate", () => {
    const reducer = new TranscriptReducer()
    reducer.consume({
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "bash",
      args: { command: "ls" },
    })
    const id = reducer.messages[0]?.id
    reducer.consume({
      type: "tool_execution_update",
      toolCallId: "tool-1",
      toolName: "bash",
      partialResult: { content: [{ type: "text", text: "partial" }] },
    })
    reducer.consume({
      type: "tool_execution_update",
      toolCallId: "tool-1",
      toolName: "bash",
      partialResult: { content: [{ type: "text", text: "replacement" }] },
    })
    expect(reducer.messages[0]?.text).toBe("bash\nreplacement")
    reducer.consume({
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "bash",
      result: { content: [{ type: "text", text: "failed output" }] },
      isError: true,
    })
    end(reducer, {
      role: "toolResult",
      toolCallId: "tool-1",
      toolName: "bash",
      content: [{ type: "text", text: "final failed output" }],
      isError: true,
    })
    expect(reducer.messages).toHaveLength(1)
    expect(reducer.messages[0]).toMatchObject({
      id,
      role: "tool",
      isError: true,
      streaming: false,
      text: "bash\nfinal failed output",
    })
  })

  test("authoritative tool success clears provisional error and interrupted tools remain visible", () => {
    const reducer = new TranscriptReducer()
    reducer.consume({
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "edit",
      isError: true,
    })
    end(reducer, {
      role: "toolResult",
      toolCallId: "tool-1",
      toolName: "edit",
      content: "successful",
      isError: false,
    })
    expect(reducer.messages[0]?.isError).toBe(false)
    reducer.consume({
      type: "tool_execution_start",
      toolCallId: "tool-2",
      toolName: "bash",
      args: {},
    })
    reducer.consume({ type: "agent_settled", aborted: true })
    expect(reducer.messages[1]).toMatchObject({ isError: true, streaming: false })
    expect(reducer.messages[1]?.text).toContain("unconfirmed")
  })

  test("assistant errors and aborts preserve their visible outcome", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    end(reducer, {
      role: "assistant",
      content: [],
      stopReason: "error",
      errorMessage: "Provider unavailable",
    })
    expect(reducer.messages[0]).toMatchObject({
      text: "Provider unavailable",
      isError: true,
      streaming: false,
    })
    start(reducer)
    end(reducer, { role: "assistant", content: [], stopReason: "aborted" })
    expect(reducer.messages[1]?.text).toContain("interrupted")
  })

  test("history omits systems, hidden custom messages, images and opaque signatures", () => {
    const reducer = new TranscriptReducer()
    reducer.replaceHistory([
      { role: "system", content: "SYSTEM_SECRET" },
      { role: "custom", display: false, content: "HIDDEN_SECRET" },
      {
        role: "user",
        content: [
          { type: "text", text: "hello" },
          { type: "image", data: "BASE64_SECRET" },
        ],
      },
      {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "visible", thinkingSignature: "SIGNATURE_SECRET" },
          { type: "text", text: "reply" },
        ],
      },
      {
        role: "toolResult",
        toolCallId: "old-tool",
        toolName: "read",
        content: [
          { type: "image", data: "BASE64_SECRET" },
          { type: "text", text: "image omitted" },
        ],
        isError: true,
      },
      { role: "unknown", content: "UNKNOWN_SECRET" },
    ])
    expect(reducer.messages).toHaveLength(3)
    expect(JSON.stringify(reducer.messages)).not.toContain("SECRET")
    expect(reducer.messages.every((message) => !message.streaming)).toBe(true)
    expect(reducer.messages[2]?.isError).toBe(true)
  })

  test("history replacement clears all live correlation and state", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    update(reducer, "text_delta", 0, { delta: "old" })
    reducer.replaceHistory([{ role: "user", content: "saved" }])
    start(reducer)
    update(reducer, "text_delta", 0, { delta: "new" })
    expect(reducer.messages.map((message) => message.text)).toEqual(["saved", "new"])
    reducer.clear()
    expect(reducer.messages).toEqual([])
  })

  test("bounds final text, thinking and tool arguments by UTF-8 bytes without replacement characters", () => {
    const reducer = new TranscriptReducer()
    end(reducer, {
      role: "assistant",
      content: [
        { type: "text", text: "🙂".repeat(100_000) },
        { type: "thinking", thinking: "é".repeat(100_000) },
      ],
    })
    const message = reducer.messages[0]
    expect(
      Buffer.byteLength(message?.text ?? "") + Buffer.byteLength(message?.thinking ?? ""),
    ).toBeLessThanOrEqual(TRANSCRIPT_LIMITS.messageBytes)
    expect(message?.truncated).toBe(true)
    expect(message?.text).not.toContain("�")
    start(reducer)
    update(reducer, "toolcall_end", 0, {
      toolCall: { name: "read", arguments: { data: "x".repeat(100_000) } },
    })
    expect(Buffer.byteLength(reducer.messages[1]?.text ?? "")).toBeLessThan(5000)
  })

  test("bounds live deltas, block indexes, history count and total retained bytes", () => {
    const reducer = new TranscriptReducer()
    start(reducer)
    for (let index = 0; index < TRANSCRIPT_LIMITS.blocks + 10; index++)
      update(reducer, "text_delta", index, { delta: "é".repeat(10_000) })
    expect(Buffer.byteLength(reducer.messages[0]?.text ?? "")).toBeLessThanOrEqual(
      TRANSCRIPT_LIMITS.messageBytes,
    )
    expect(reducer.messages[0]?.truncated).toBe(true)
    reducer.replaceHistory(
      Array.from({ length: 300 }, () => ({
        role: "user",
        content: "x".repeat(TRANSCRIPT_LIMITS.messageBytes),
      })),
    )
    expect(reducer.messages.length).toBeLessThanOrEqual(TRANSCRIPT_LIMITS.messages)
    expect(
      reducer.messages.reduce((sum, message) => sum + Buffer.byteLength(message.text), 0),
    ).toBeLessThanOrEqual(TRANSCRIPT_LIMITS.totalBytes)
    reducer.replaceHistory(
      Array.from({ length: 300 }, (_, index) => ({ role: "user", content: String(index) })),
    )
    expect(reducer.messages).toHaveLength(TRANSCRIPT_LIMITS.messages)
    expect(reducer.messages[0]?.text).toBe("100")
  })

  test("removes terminal control sequences and cannot mutate through returned messages", () => {
    const reducer = new TranscriptReducer()
    end(reducer, {
      role: "user",
      content: "\u001b[31mred\u001b[0m\u001b]0;title\u0007\u0000\nnext\tline",
    })
    expect(reducer.messages[0]?.text).toBe("red\nnext\tline")
    const messages = reducer.messages
    if (messages[0]) messages[0].text = "changed"
    messages.pop()
    expect(reducer.messages[0]?.text).toBe("red\nnext\tline")
  })

  test("malformed and future event shapes do not crash or retain unknown data", () => {
    const reducer = new TranscriptReducer()
    for (const event of [
      { type: "future_event", data: "secret" },
      { type: "message_start", message: null },
      { type: "message_end", message: [] },
      {
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", contentIndex: -1, delta: "secret" },
      },
      { type: "tool_execution_start", toolCallId: 1 },
    ])
      reducer.consume(event)
    expect(reducer.messages).toEqual([])
  })
})
