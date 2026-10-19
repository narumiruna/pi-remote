import { describe, expect, test } from "bun:test"
import { Buffer } from "node:buffer"
import { createHmac } from "node:crypto"
import { readFileSync } from "node:fs"
import {
  DEFERRED_ACTIONS,
  decodeClient,
  enumValue,
  initialSnapshot,
  MAX_PACKET_BYTES,
  ProtocolError,
  packet,
  type RemoteFault,
  SUPPORTED_ACTIONS,
} from "./protocol"

const fixtures = JSON.parse(
  readFileSync(new URL("../fixtures/wire-v1.json", import.meta.url), "utf8"),
) as {
  generatedBy: string
  authentication: { device: string; secret: string; nonce: string; proof: string }
  client: { name: string; packet: Record<string, unknown> }[]
  server: { name: string; packet: { version: number; payload: Record<string, unknown> } }[]
}
const id = "01234567-89ab-cdef-0123-456789abcdef"
const canonical = id.toUpperCase()
function request(action: string, fields: Record<string, unknown> = {}): string {
  return JSON.stringify({
    version: 1,
    payload: { request: { _0: { id, epoch: id, action: { [action]: fields } } } },
  })
}
function rejects(value: string | Uint8Array, code: RemoteFault = "invalidRequest"): void {
  try {
    decodeClient(value)
    throw new Error("Packet was accepted")
  } catch (error) {
    expect(error).toBeInstanceOf(ProtocolError)
    expect((error as ProtocolError).code).toBe(code)
  }
}

describe("Swift JSONEncoder golden contract", () => {
  test("all first-milestone and deferred actions decode from Swift output", () => {
    expect(fixtures.generatedBy).toBe("CLIClientCheck --fixtures; Foundation JSONEncoder")
    const covered = new Set<string>()
    for (const fixture of fixtures.client) {
      const decoded = decodeClient(JSON.stringify(fixture.packet))
      if (decoded.kind === "request") {
        covered.add(decoded.action)
        expect(decoded.id).toBe("11223344-5566-7788-99AA-BBCCDDEEFF00")
        expect(decoded.epoch).toBe("ABCDEF01-2345-6789-ABCD-EF0123456789")
      } else {
        expect(decoded.device).toBe("11223344-5566-7788-99AA-BBCCDDEEFF00")
        expect(decoded.kind === "pair" ? decoded.grant : decoded.proof).toEqual(
          decoded.kind === "pair"
            ? Buffer.from(Array.from({ length: 32 }, (_, i) => i))
            : Buffer.from(fixtures.authentication.proof, "base64"),
        )
      }
    }
    expect([...covered].sort()).toEqual([...SUPPORTED_ACTIONS, ...DEFERRED_ACTIONS].sort())
  })
  test("Swift HMAC fixture uses canonical uppercase UUID input", () => {
    const { secret, device, nonce, proof } = fixtures.authentication
    const expected = createHmac("sha256", Buffer.from(secret, "base64"))
      .update(Buffer.from(`PiRemote app protocol v1\0${device}\0`, "utf8"))
      .update(Buffer.from(nonce, "base64"))
      .digest("base64")
    expect(expected).toBe(proof)
    expect(device).toBe(device.toUpperCase())
  })
  test("server envelopes preserve enum, Date, Range, UUID and Base64 encodings", () => {
    for (const fixture of fixtures.server) {
      expect(JSON.parse(packet(fixture.packet.payload))).toEqual(fixture.packet)
    }
    const state = fixtures.server.find((f) => f.name === "state")?.packet.payload.state as {
      _0: Record<string, unknown>
    }
    expect(state._0.sequence).toBe(Number.MAX_SAFE_INTEGER)
    expect((state._0.sessions as { updated: number }[])[0]?.updated).toBe(123.5)
    expect((state._0.messages as { toolCallRanges: number[][] }[])[0]?.toolCallRanges).toEqual([
      [0, 7],
    ])
    expect(enumValue("ok")).toEqual({ ok: {} })
    expect(enumValue("failure", "unsupportedFeature")).toEqual({
      failure: { _0: "unsupportedFeature" },
    })
  })
  test("minimal CLI snapshot has all mandatory Swift fields", () => {
    const snapshot = initialSnapshot(id, id)
    const golden = fixtures.server.find((f) => f.name === "state")?.packet.payload.state as {
      _0: Record<string, unknown>
    }
    for (const field of Object.keys(snapshot)) expect(Object.hasOwn(golden._0, field)).toBe(true)
    expect(snapshot.host).toBe(canonical)
    expect(snapshot.capabilities).not.toContain("clone")
    expect(snapshot.capabilities).not.toContain("images")
  })
})

describe("bounded client validation", () => {
  test("canonicalizes all UUID arguments before HMAC or ID lookup", () => {
    const decoded = decodeClient(request("directories", { id, cursor: id }))
    expect(decoded).toEqual({
      kind: "request",
      id: canonical,
      epoch: canonical,
      action: "directories",
      fields: { id: canonical, cursor: canonical },
    })
    expect(decodeClient(new TextEncoder().encode(request("snapshot")))).toEqual(
      decodeClient(request("snapshot")),
    )
  })
  test("rejects invalid JSON, UTF-8, version, object and enum forms", () => {
    for (const value of [
      "null",
      "[]",
      "{",
      "{}",
      '{"version":1,"payload":{}}',
      '{"version":1,"payload":{"pair":{},"authenticate":{}}}',
      '{"version":1,"payload":{"request":[]}}',
    ]) {
      rejects(value, value === "{}" ? "unsupportedVersion" : "invalidRequest")
    }
    rejects('{"version":2,"payload":{}}', "unsupportedVersion")
    rejects(new Uint8Array([0xff]))
    rejects(request("notAnAction"))
    rejects(request("__proto__"))
    rejects(request("snapshot").replace('"snapshot":{}', '"snapshot":{},"stop":{}'))
    rejects(request("snapshot").replace('"snapshot":{}', '"snapshot":{},"snapshot":{}'))
    rejects(request("snapshot").replace('"snapshot":{}', '"snapshot":{},"snap\\u0073hot":{}'))
  })
  test("rejects oversized UTF-8 input and output", () => {
    rejects(" ".repeat(MAX_PACKET_BYTES + 1), "tooLarge")
    rejects("😀".repeat(MAX_PACKET_BYTES / 4 + 1), "tooLarge")
    expect(() => packet(enumValue("state", { text: "x".repeat(MAX_PACKET_BYTES) }))).toThrow(
      "tooLarge",
    )
  })
  test("checks original numeric tokens without JavaScript precision loss", () => {
    for (const after of [
      "-1",
      "1.5",
      "9007199254740992",
      "9007199254740993",
      "9007199254740991.1",
      "1.0000000000000001",
      "1e999",
      "1e-999",
      "900719925474099100000e-4",
    ]) {
      rejects(request("synchronize", { after: 0 }).replace('"after":0', `"after":${after}`))
    }
    for (const after of ["0", "1e0", "10e-1", "9007199254740991", "90071992547409910e-1"]) {
      const decoded = decodeClient(
        request("synchronize", { after: 0 }).replace('"after":0', `"after":${after}`),
      )
      expect(decoded.kind).toBe("request")
    }
    expect(() => packet(enumValue("state", { sequence: Number.MAX_SAFE_INTEGER + 1 }))).toThrow(
      "invalidRequest",
    )
    expect(() => packet(enumValue("state", { sequence: 1.5 }))).toThrow("invalidRequest")
    expect(() => packet(enumValue("state", { sequence: -1 }))).toThrow("invalidRequest")
    expect(() => packet(enumValue("state", { sequence: Number.NaN }))).toThrow("invalidRequest")
  })
  test("validates canonical Base64, secret lengths and UUIDs", () => {
    const pair = (grant: unknown, device: unknown = id) =>
      JSON.stringify({ version: 1, payload: { pair: { device, name: "fixture", grant } } })
    for (const grant of [
      "!",
      "Zg",
      "Zh==",
      "Zg==\n",
      "",
      [],
      null,
      Buffer.alloc(31).toString("base64"),
      Buffer.alloc(33).toString("base64"),
    ])
      rejects(pair(grant))
    for (const device of ["not-uuid", `{${id}}`, id.replaceAll("-", ""), 1])
      rejects(pair(Buffer.alloc(32).toString("base64"), device))
    const decoded = decodeClient(pair(Buffer.alloc(32).toString("base64")))
    expect(decoded.kind).toBe("pair")
    expect("device" in decoded && decoded.device).toBe(canonical)
  })
  test("validates all supported arguments and known deferred operations", () => {
    const malformed: [string, Record<string, unknown>][] = [
      ["directories", { id: "bad" }],
      ["directories", { cursor: 1 }],
      ["directoryAtPath", {}],
      ["createSession", { directory: "bad" }],
      ["resumeSession", { id: false }],
      ["prompt", { text: 1, delivery: "prompt" }],
      ["prompt", { text: "fixture", delivery: "steering" }],
      [
        "prompt",
        { text: "fixture", delivery: "prompt", image: { data: "!", mimeType: "image/png" } },
      ],
      ["model", { provider: "fixture" }],
      ["thinking", {}],
      ["command", { name: "fixture" }],
      ["answer", { dialog: "fixture", cancelled: "false" }],
      ["answer", { dialog: "fixture", cancelled: false, confirmed: 1 }],
      ["newSession", { parent: 1 }],
      ["importSession", { data: "!" }],
      ["releaseNotes", { offset: -1 }],
      ["queueMode", { kind: "prompt", mode: "all" }],
      ["queueMode", { kind: "steering", mode: "invalid" }],
    ]
    for (const [action, args] of malformed) rejects(request(action, args))
    expect(decodeClient(request("clone")).kind).toBe("request")
    expect(decodeClient(request("synchronize", { epoch: null, after: null }))).toMatchObject({
      fields: {},
    })
  })
  test("sanitized validation errors do not contain prompt or grant contents", () => {
    const secret = "private-fixture-content"
    try {
      decodeClient(request("prompt", { text: secret, delivery: secret }))
      throw new Error("accepted")
    } catch (error) {
      expect(String(error)).not.toContain(secret)
    }
  })
})
