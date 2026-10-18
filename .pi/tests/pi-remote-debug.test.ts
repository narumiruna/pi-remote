import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { chmod, link, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { execFile, execFileSync, spawn } from "node:child_process";
import { promisify } from "node:util";
import { createServer, type Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { randomBytes } from "node:crypto";
import { deflateSync, inflateSync } from "node:zlib";
import extension, { DebugClient, validateCapture, validateInteraction, validateInteractionResult, validateResponse, validateStatus } from "../extensions/pi-remote-debug.ts";

const status = { interfaceMode: "pi", destination: "conversation", windowWidth: 1200, windowHeight: 800, sessionPresent: true, phase: "idle", listenerOn: false, sessionCount: 1, messageCount: 2, dialogCount: 0 };
const token = "ab".repeat(32);
const cleanup: (() => Promise<unknown> | unknown)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });

function crc32(bytes: Buffer) {
  let c = 0xffffffff;
  for (const b of bytes) { c ^= b; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); }
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Buffer) {
  const out = Buffer.alloc(data.length + 12);
  out.writeUInt32BE(data.length); out.write(type, 4); data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, -4)), out.length - 4);
  return out;
}
function png(width = 1, height = 1, raw?: Buffer) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", header), chunk("IDAT", deflateSync(raw ?? Buffer.alloc((width * 4 + 1) * height))), chunk("IEND", Buffer.alloc(0))]);
}
function capture() { return { png: png().toString("base64"), width: 1, height: 1, capturedAt: "2026-10-18T10:00:00.123Z", method: "appkit-view" }; }
function wire(id: unknown, result: unknown = status) { return JSON.stringify({ version: 1, id, ok: true, result }) + "\n"; }
async function until(check: () => boolean) {
  for (let i = 0; i < 200; i++) { if (check()) return; await new Promise(r => setTimeout(r, 5)); }
  assert.fail("fixture condition did not complete");
}
async function fixture(handler: (request: any, socket: Socket) => void = (r, s) => s.end(wire(r.id)), nestedHome = false, baseDirectory = homedir()) {
  // Most fixtures use HOME to avoid temporary-directory symlink aliases.
  // Canonical root-owned sticky parents have a separate test below.
  const home = await mkdtemp(join(baseDirectory, ".pi-remote-debug-test-"));
  const directory = nestedHome ? join(home, "Library", "Caches", "PiRemoteDebug") : home;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const sockets = new Set<Socket>();
  const requests: any[] = [];
  const socketRequests = new Map<Socket, any>();
  let connectionCount = 0;
  const server = createServer(socket => {
    connectionCount++;
    sockets.add(socket); socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
    let input = "";
    socket.on("data", bytes => {
      input += bytes.toString();
      if (!input.endsWith("\n")) return;
      assert.ok(Buffer.byteLength(input) <= 4096);
      const request = JSON.parse(input); requests.push(request); socketRequests.set(socket, request); handler(request, socket);
    });
  });
  const socketPath = join(directory, "control.sock");
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
  await chmod(socketPath, 0o600);
  const endpoint = join(directory, "endpoint.json");
  await writeFile(endpoint, JSON.stringify({ version: 1, socketPath, token }), { mode: 0o600 });
  const client = new DebugClient(directory);
  cleanup.push(async () => { client.close(); for (const socket of sockets) socket.destroy(); await new Promise<void>(r => server.close(() => r())); await rm(home, { recursive: true, force: true }); });
  return { home, directory, socketPath, endpoint, client, requests, sockets, socketRequests, get connectionCount() { return connectionCount; } };
}

const allowedInteractions = {
  navigate: ["conversation", "overview", "settings", "devices"],
  interface_mode: ["pi", "desktop"], sidebar: ["show", "hide"],
  inspector: ["Files", "Session", "Activity", "hide"],
  panel: ["commands", "resume", "palette", "hotkeys", "directory", "workspace", "close"],
  type_text: ["private draft\n☃"], focus_editor: ["editor"],
  scroll: ["history_up", "history_down", "history_top", "history_bottom", "dock_up", "dock_down", "page_up", "page_down"],
};
const invalidInteraction = { message: "Pi Remote debug interaction is invalid or exceeds its size limit." };
const invalidResponse = { message: "Pi Remote debug returned an invalid response." };

test("interact sends only the strict version-1 fields for every allowed action/value pair", async () => {
  const f = await fixture((r, s) => s.end(wire(r.id, { action: r.interaction.action, outcome: "applied" })));
  for (const [action, values] of Object.entries(allowedInteractions)) for (const value of values) {
    const interaction = { action, value };
    assert.deepEqual(validateInteraction(interaction), interaction);
    const result = await f.client.request("interact", undefined, interaction as any);
    assert.deepEqual(result, { action, outcome: "applied" });
    const request = f.requests.at(-1);
    assert.deepEqual(Object.keys(request).sort(), ["id", "interaction", "operation", "token", "version"]);
    assert.deepEqual(request.interaction, interaction);
    assert.equal(request.version, 1); assert.equal(request.operation, "interact"); assert.equal(request.token, token);
    assert.match(request.id, /^[0-9a-f-]{36}$/);
  }
  assert.equal(f.connectionCount, f.requests.length);
});

test("invalid action/value pairs, missing/extra fields and types fail before a socket opens", async () => {
  const f = await fixture();
  const invalid: unknown[] = [undefined, null, [], {}, { action: "sidebar" }, { value: "show" },
    { action: "sidebar", value: "show", extra: token }, { action: "sidebar", value: 1 },
    { action: 1, value: "show" }, { action: "type_text", value: "" },
    ...["submit", "execute", "__proto__", "constructor", "toString", "NAVIGATE"].map(action => ({ action, value: token }))];
  const allValues = [...new Set(Object.values(allowedInteractions).flat()), "files", "session", "activity", "workspace", token];
  for (const [action, values] of Object.entries(allowedInteractions)) {
    if (action === "type_text") continue;
    for (const value of allValues) if (!values.includes(value)) invalid.push({ action, value });
  }
  for (const input of invalid) {
    assert.throws(() => validateInteraction(input), invalidInteraction);
    await assert.rejects(f.client.request("interact", undefined, input as any), invalidInteraction);
  }
  await assert.rejects(f.client.request("status", undefined, { action: "sidebar", value: "show" }), invalidInteraction);
  await assert.rejects(f.client.request("capture", undefined, { action: "sidebar", value: "show" }), invalidInteraction);
  await assert.rejects(f.client.request("submit" as any), { message: "Pi Remote debug operation is unsupported." });
  assert.equal(f.requests.length, 0); assert.equal(f.connectionCount, 0);
});

test("text uses the 2048 UTF-8 byte limit and the encoded request keeps the 4096-byte limit", async () => {
  const f = await fixture((r, s) => s.end(wire(r.id, { action: "type_text", outcome: "applied" })));
  for (const value of ["a".repeat(2048), "😀".repeat(512), "☃".repeat(682) + "ab", " ", "\n"]) {
    assert.deepEqual(await f.client.request("interact", undefined, { action: "type_text", value }), { action: "type_text", outcome: "applied" });
  }
  for (const value of ["a".repeat(2049), "😀".repeat(512) + "a", "☃".repeat(683), "\0".repeat(2048), "\n".repeat(2048), '"'.repeat(2048)]) {
    const before = f.connectionCount;
    await assert.rejects(f.client.request("interact", undefined, { action: "type_text", value }), invalidInteraction);
    assert.equal(f.connectionCount, before);
  }
  const encodedSize = (value: string) => Buffer.byteLength(JSON.stringify({ version: 1, id: "0".repeat(36), token, operation: "interact", interaction: { action: "type_text", value } }) + "\n");
  let value = "";
  while (encodedSize(value + "\u0001") <= 4096) value += "\u0001";
  value += "x".repeat(4096 - encodedSize(value));
  assert.ok(Buffer.byteLength(value) <= 2048); assert.equal(encodedSize(value), 4096);
  await f.client.request("interact", undefined, { action: "type_text", value });
  const before = f.connectionCount;
  await assert.rejects(f.client.request("interact", undefined, { action: "type_text", value: value + "x" }), invalidInteraction);
  assert.equal(f.connectionCount, before);
});

test("interaction responses require exactly the matching allowed action and applied outcome", async () => {
  assert.deepEqual(validateInteractionResult({ action: "sidebar", outcome: "applied" }, "sidebar"), { action: "sidebar", outcome: "applied" });
  for (const result of [null, [], {}, { action: "sidebar" }, { action: "sidebar", outcome: "failed" },
    { action: "submit", outcome: "applied" }, { action: "navigate", outcome: "applied" },
    { action: "sidebar", outcome: "applied", value: token }, { action: "sidebar", outcome: "applied", text: token }]) {
    assert.throws(() => validateResponse(Buffer.from(wire("id", result)), "id", "interact", "sidebar"), invalidResponse);
    const f = await fixture((r, s) => s.end(wire(r.id, result)));
    await assert.rejects(f.client.request("interact", undefined, { action: "sidebar", value: "show" }), invalidResponse);
    assert.equal(f.connectionCount, 1); assert.equal(f.requests.length, 1);
  }
});

test("interaction server errors use fixed safe text without retries or response text", async () => {
  const messages = {
    interaction_blocked: "Pi Remote debug interaction is blocked while a protected surface is visible.",
    invalid_interaction: invalidInteraction.message,
    target_unavailable: "Pi Remote debug interaction target is unavailable.",
    unsupported_operation: "Pi Remote debug operation is unsupported.",
    [token]: "Pi Remote debug operation failed.",
  };
  for (const [error, message] of Object.entries(messages)) {
    const f = await fixture((r, s) => s.end(JSON.stringify({ version: 1, id: r.id, ok: false, error }) + "\n"));
    await assert.rejects(f.client.request("interact", undefined, { action: "type_text", value: token }), { message });
    assert.equal(f.connectionCount, 1); assert.equal(f.requests.length, 1);
  }
});

test("interaction timeout, abort and shutdown warn about uncertain application and never retry", async () => {
  const warning = " The interaction may already apply. Inspect the app before retrying. No automatic retry was made.";
  const input = { action: "type_text", value: token } as const;
  const f = await fixture(() => {});
  await assert.rejects(f.client.request("interact", AbortSignal.abort(token), input), { message: "Pi Remote debug request was cancelled." + warning });
  assert.equal(f.connectionCount, 0);
  const controller = new AbortController();
  const pending = f.client.request("interact", controller.signal, input);
  await until(() => f.requests.length === 1); controller.abort(token);
  await assert.rejects(pending, { message: "Pi Remote debug request was cancelled." + warning });
  await until(() => f.sockets.size === 0);
  await assert.rejects(f.client.request("interact", undefined, input), { message: "Pi Remote debug timed out after 5 seconds. No request was retried." + warning });
  await until(() => f.sockets.size === 0);
  const closing = f.client.request("interact", undefined, input);
  await until(() => f.requests.length === 3); f.client.close(); f.client.close();
  await assert.rejects(closing, { message: "Pi Remote debug request was cancelled." + warning });
  await assert.rejects(f.client.request("interact", undefined, input), { message: "Pi Remote debug request was cancelled." + warning });
  await until(() => f.sockets.size === 0);
  assert.equal(f.requests.length, 3); assert.equal(f.connectionCount, 3);
  for (const error of ["timeout", "cancelled"]) {
    assert.throws(() => validateResponse(Buffer.from(JSON.stringify({ version: 1, id: "id", ok: false, error })), "id", "interact", "type_text"), e => e instanceof Error && e.message.endsWith(warning));
  }
});

test("status call connects on demand with one bounded UUID request and sanitized output", async () => {
  const f = await fixture(); assert.equal(f.requests.length, 0);
  assert.deepEqual(await f.client.request("status"), status);
  assert.equal(f.requests.length, 1);
  assert.deepEqual(Object.keys(f.requests[0]).sort(), ["id", "operation", "token", "version"]);
  assert.match(f.requests[0].id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(f.requests[0].token, token); assert.equal(f.requests[0].operation, "status");
  assert.ok(!JSON.stringify(await f.client.request("status")).includes(token));
  await until(() => f.sockets.size === 0);
});

test("strict status allowlist rejects unknown fields, dynamic text, invalid bounds and types", () => {
  assert.deepEqual(validateStatus(status), status);
  for (const phase of ["queued", "bash"]) assert.equal(validateStatus({ ...status, phase }).phase, phase);
  for (const changed of [{ prompt: token }, { phase: token }, { destination: "/private/path" }, { interfaceMode: "other" }, { windowWidth: -1 }, { windowHeight: 16385 }, { sessionCount: 10001 }, { messageCount: 1.5 }, { dialogCount: Infinity }, { listenerOn: 1 }, { sessionPresent: "true" }]) {
    assert.throws(() => validateStatus({ ...status, ...changed }), { message: "Pi Remote debug returned an invalid response." });
  }
  assert.throws(() => validateStatus({})); assert.throws(() => validateStatus(null));
});

test("capture returns decodable PNG and bounded AppKit metadata", async () => {
  const f = await fixture((r, s) => s.end(wire(r.id, capture())));
  const result = await f.client.request("capture"); assert.ok("image" in result);
  assert.equal(result.image.mimeType, "image/png"); assert.equal(result.image.type, "image");
  const decoded = Buffer.from(result.image.data, "base64"); assert.deepEqual(decoded, png());
  assert.equal(decoded.readUInt32BE(16), result.metadata.width); assert.equal(decoded.readUInt32BE(20), result.metadata.height);
  assert.deepEqual(inflateSync(decoded.subarray(41, decoded.length - 16)), Buffer.alloc(5));
  assert.deepEqual(result.metadata, { width: 1, height: 1, capturedAt: capture().capturedAt, method: "appkit-view" });
  assert.throws(() => validateCapture({ ...capture(), method: "screencapturekit-window" }));
});

test("capture accepts large valid PNGs and rejects byte, edge and pixel limits", () => {
  const raw = randomBytes(1600400);
  for (let i = 0; i < 400; i++) raw[i * 4001] = 0;
  const large = { ...capture(), width: 1000, height: 400, png: png(1000, 400, raw).toString("base64") };
  assert.ok(large.png.length > 2 * 1024 * 1024);
  assert.equal(validateCapture(large).image.data, large.png);
  const bounded = { ...capture(), width: 1920, height: 1200, png: png(1920, 1200).toString("base64") };
  assert.equal(validateCapture(bounded).metadata.width, 1920);
  assert.throws(() => validateCapture({ ...bounded, height: 1201 }));
  assert.throws(() => validateCapture({ ...large, png: randomBytes(2 * 1024 * 1024 + 1).toString("base64") }));
});

test("capture rejects invalid PNG, metadata, dimensions, compressed expansion and unknown fields", () => {
  const broken = png(); broken[45] ^= 1;
  for (const changed of [{ token }, { windowID: 1 }, { width: 0 }, { height: 1921 }, { width: 1920, height: 1920 }, { width: 2 }, { method: "desktop" }, { capturedAt: "private" }, { capturedAt: "2026-02-30T10:00:00Z" }, { png: "YWJj" }, { png: "%%%=" }, { png: broken.toString("base64") }, { png: png(1, 1, Buffer.alloc(1000000)).toString("base64") }, { png: "a".repeat(4 * Math.ceil(2 * 1024 * 1024 / 3) + 4) }]) {
    assert.throws(() => validateCapture({ ...capture(), ...changed }));
  }
  assert.throws(() => validateCapture({ ...capture(), png: Buffer.concat([png(), Buffer.from("private")]).toString("base64") }));
});

test("response validates version, matching id, success shape, UTF-8 and safe errors", () => {
  const good = { version: 1, id: "expected", ok: true, result: status };
  for (const changed of [{ version: 2 }, { id: "wrong" }, { ok: 1 }, { token }]) {
    assert.throws(() => validateResponse(Buffer.from(JSON.stringify({ ...good, ...changed })), "expected", "status"));
  }
  for (const bytes of [Buffer.from("{"), Buffer.from([0xff]), Buffer.from("null"), Buffer.from("[]")]) assert.throws(() => validateResponse(bytes, "expected", "status"));
  for (const error of [token, { code: token }, "capture_protected", "permission_required", "disabled"]) {
    assert.throws(() => validateResponse(Buffer.from(JSON.stringify({ version: 1, id: "expected", ok: false, error })), "expected", "capture"), e => e instanceof Error && !e.message.includes(token));
  }
});

test("socket rejects malformed, mismatched, oversized and multiple response records without retry", async () => {
  for (const send of [
    (r: any) => "not-json\n", (r: any) => wire("wrong"), (r: any) => wire(r.id) + wire(r.id),
    (r: any) => "x".repeat(3 * 1024 * 1024 + 1), (r: any) => wire(r.id, { ...status, secret: token }),
    (r: any) => wire(r.id).trimEnd(),
  ]) {
    const f = await fixture((r, s) => s.end(send(r)));
    await assert.rejects(f.client.request("status"), { message: "Pi Remote debug returned an invalid response." });
    assert.equal(f.requests.length, 1);
  }
});

test("multiple records in separate response chunks are rejected", async () => {
  const f = await fixture((r, s) => { s.write(wire(r.id)); setImmediate(() => s.end(wire(r.id))); });
  await assert.rejects(f.client.request("status"), { message: "Pi Remote debug returned an invalid response." });
});

test("fragmented JSONL responses are accepted", async () => {
  const f = await fixture((r, s) => { const response = wire(r.id); s.write(response.slice(0, 8)); setImmediate(() => s.end(response.slice(8))); });
  assert.deepEqual(await f.client.request("status"), status);
});

test("absent endpoint and stale socket return a fixed error without leaking paths or token", async () => {
  const f = await fixture(); await rm(f.endpoint);
  await assert.rejects(f.client.request("status"), { message: "Pi Remote debug is unavailable. Enable debug mode in the Mac app Settings." });
  await writeFile(f.endpoint, JSON.stringify({ version: 1, socketPath: f.socketPath, token }), { mode: 0o600 });
  await rm(f.socketPath);
  await assert.rejects(f.client.request("status"), e => e instanceof Error && !e.message.includes(f.directory) && !e.message.includes(token));
  assert.equal(f.requests.length, 0);
});

test("discovery rejects permissions, symlinks, shared parents, oversized records and unsafe paths", async () => {
  const f = await fixture(); const original = await readFile(f.endpoint);
  const unsafe = { message: "Pi Remote debug endpoint permissions or paths are unsafe." };
  for (const path of [f.directory, f.endpoint, f.socketPath]) {
    await chmod(path, 0o777); await assert.rejects(f.client.request("status"), unsafe); await chmod(path, path === f.directory ? 0o700 : 0o600);
  }
  for (const discovery of [{ version: 2, socketPath: f.socketPath, token }, { version: 1, socketPath: "/tmp/control.sock", token }, { version: 1, socketPath: f.socketPath, token: "bad" }, { version: 1, socketPath: f.socketPath, token, extra: token }]) {
    await writeFile(f.endpoint, JSON.stringify(discovery)); await assert.rejects(f.client.request("status"), unsafe);
  }
  await writeFile(f.endpoint, "x".repeat(4097)); await assert.rejects(f.client.request("status"), unsafe);
  await writeFile(f.endpoint, original);
  const alias = join(f.directory, "alias"); await symlink(f.directory, alias);
  await assert.rejects(new DebugClient(alias).request("status"), unsafe);
  const target = join(f.directory, "real.json"); await writeFile(target, original, { mode: 0o600 });
  await rm(f.endpoint); await symlink(target, f.endpoint); await assert.rejects(f.client.request("status"), unsafe);
  await rm(f.endpoint); await link(target, f.endpoint); await assert.rejects(f.client.request("status"), unsafe);
  await rm(f.endpoint); await writeFile(f.endpoint, original, { mode: 0o600 });
  await rm(f.socketPath); await symlink(target, f.socketPath); await assert.rejects(f.client.request("status"), unsafe);
  const parent = join(f.directory, "shared"); await mkdir(parent, { mode: 0o777 }); await chmod(parent, 0o777);
  const child = join(parent, "private"); await mkdir(child, { mode: 0o700 });
  await assert.rejects(new DebugClient(child).request("status"), unsafe);
  await assert.rejects(new DebugClient(join(f.directory, "..", "invalid") + "/../").request("status"), unsafe);
  assert.equal(f.requests.length, 0);
});

test("root-owned sticky system parents are accepted without accepting symlinks", async () => {
  const systemTemporary = await realpath("/tmp"); const info = await lstat(systemTemporary);
  assert.equal(info.uid, 0); assert.ok(info.mode & 0o1000);
  const f = await fixture(undefined, false, systemTemporary);
  assert.deepEqual(await f.client.request("status"), status);
});

test("deadline is five seconds, destroys the client and does not retry", async () => {
  const f = await fixture(() => {}); const start = performance.now();
  await assert.rejects(f.client.request("status"), { message: "Pi Remote debug timed out after 5 seconds. No request was retried." });
  assert.ok(performance.now() - start >= 4900); assert.ok(performance.now() - start < 6500);
  await until(() => f.sockets.size === 0); assert.equal(f.requests.length, 1);
});

test("already aborted and in-flight AbortSignal calls clean up and never retry", async () => {
  const f = await fixture(() => {}); const already = AbortSignal.abort(new Error(token));
  await assert.rejects(f.client.request("status", already), { message: "Pi Remote debug request was cancelled." });
  assert.equal(f.requests.length, 0);
  const controller = new AbortController(); const pending = f.client.request("status", controller.signal);
  await until(() => f.requests.length === 1); controller.abort(token);
  await assert.rejects(pending, { message: "Pi Remote debug request was cancelled." });
  await until(() => f.sockets.size === 0); assert.equal(f.requests.length, 1);
});

test("four concurrent calls have isolated connections; cancelling one preserves the others", async () => {
  const f = await fixture(() => {}); const controllers = Array.from({ length: 4 }, () => new AbortController());
  const calls = controllers.map(c => f.client.request("status", c.signal));
  await until(() => f.requests.length === 4); assert.equal(f.sockets.size, 4);
  controllers[0].abort(); await assert.rejects(calls[0]); await until(() => f.sockets.size === 3);
  for (const socket of f.sockets) socket.end(wire(f.socketRequests.get(socket).id));
  for (const call of calls.slice(1)) assert.deepEqual(await call, status);
  assert.equal(new Set(f.requests.map(r => r.id)).size, 4);
});

test("shutdown/reload cleanup cancels every owned call, is idempotent and blocks stale clients", async () => {
  const f = await fixture(() => {}); const calls = [f.client.request("status"), f.client.request("capture")];
  await until(() => f.requests.length === 2); f.client.close(); f.client.close();
  for (const call of calls) await assert.rejects(call, { message: "Pi Remote debug request was cancelled." });
  await until(() => f.sockets.size === 0);
  await assert.rejects(f.client.request("status"), { message: "Pi Remote debug request was cancelled." });
  assert.equal(f.requests.length, 2);
});

test("CLI probe uses the registered tool, reports only image summary and creates no image artifact", async () => {
  const white = { ...capture(), png: png(1, 1, Buffer.from([0, 255, 255, 255, 255])).toString("base64") };
  const f = await fixture((r, s) => s.end(wire(r.id, r.operation === "status" ? status : white)), true);
  const run = promisify(execFile);
  const options = { env: { ...process.env, HOME: f.home }, timeout: 10000 };
  const statusProbe = JSON.parse((await run(process.execPath, [".pi/tests/debug-probe.ts", "status"], options)).stdout);
  assert.deepEqual(statusProbe, { ok: true, status });
  const output = (await run(process.execPath, [".pi/tests/debug-probe.ts", "capture"], options)).stdout;
  const summary = JSON.parse(output);
  assert.equal(summary.ok, true); assert.equal(summary.width, 1); assert.equal(summary.height, 1); assert.equal(summary.meanLuminance, 255);
  assert.match(summary.sha256, /^[a-f0-9]{64}$/); assert.ok(!output.includes(token)); assert.ok(!output.includes(white.png));
  assert.deepEqual((await readdir(f.directory)).sort(), ["control.sock", "endpoint.json"]);
  await rm(f.endpoint);
  await assert.rejects(run(process.execPath, [".pi/tests/debug-probe.ts", "status"], options), e => {
    assert.ok(e instanceof Error && "stdout" in e); const error = JSON.parse(String(e.stdout));
    assert.equal(error.ok, false); assert.ok(!JSON.stringify(error).includes(token)); return true;
  });
});

test("CLI capture probe preserves fixed protection and window errors without exposing raw server text", async () => {
  for (const [code, message] of [
    ["capture_protected", "Capture is blocked while a protected surface is visible."],
    ["window_unavailable", "The Pi Remote window is unavailable. Show the main window and try again."],
    ["window_ambiguous", "The Pi Remote window selection is ambiguous."],
    [token, "Pi Remote debug operation failed."],
  ]) {
    const f = await fixture((r, s) => s.end(JSON.stringify({ version: 1, id: r.id, ok: false, error: code }) + "\n"), true);
    await assert.rejects(promisify(execFile)(process.execPath, [".pi/tests/debug-probe.ts", "capture"],
      { env: { ...process.env, HOME: f.home }, timeout: 10000 }), error => {
        assert.ok(error instanceof Error && "stdout" in error && "stderr" in error);
        assert.deepEqual(JSON.parse(String(error.stdout)), { ok: false, error: message });
        assert.equal(error.stderr, "");
        assert.ok(!String(error.stdout).includes(token));
        return true;
      });
  }
});

test("CLI interaction probe uses the installed loader without logging values on success or failure", async () => {
  const f = await fixture((r, s) => s.end(wire(r.id, { action: r.interaction.action, outcome: "applied" })), true);
  const run = promisify(execFile);
  const options = { env: { ...process.env, HOME: f.home }, timeout: 10000 };
  const output = await run(process.execPath, [".pi/tests/debug-probe.ts", "interact", "type_text", token], options);
  assert.deepEqual(JSON.parse(output.stdout), { ok: true, action: "type_text", outcome: "applied" });
  assert.equal(output.stderr, ""); assert.ok(!output.stdout.includes(token));
  assert.deepEqual(f.requests[0].interaction, { action: "type_text", value: token });
  await assert.rejects(run(process.execPath, [".pi/tests/debug-probe.ts", "interact", "navigate", token], options), e => {
    assert.ok(e instanceof Error && "stdout" in e && "stderr" in e);
    assert.deepEqual(JSON.parse(String(e.stdout)), { ok: false, error: invalidInteraction.message });
    assert.equal(e.stderr, ""); assert.ok(!String(e.stdout).includes(token)); return true;
  });
  await assert.rejects(run(process.execPath, [".pi/tests/debug-probe.ts", "interact", "type_text"], options), e => {
    assert.ok(e instanceof Error && "stderr" in e && "code" in e);
    assert.equal(e.code, 2); assert.match(String(e.stderr), /^Usage:/); return true;
  });
  assert.equal(f.requests.length, 1); assert.equal(f.connectionCount, 1);
  assert.deepEqual((await readdir(f.directory)).sort(), ["control.sock", "endpoint.json"]);
});

test("real installed Pi RPC executes all tools before and after reload with no saved session", { timeout: 20000 }, async () => {
  const f = await fixture((r, s) => s.end(wire(r.id, r.operation === "status" ? status : r.operation === "interact" ? { action: r.interaction.action, outcome: "applied" } : capture())), true);
  const cli = await realpath(execFileSync("which", ["pi"], { encoding: "utf8" }).trim());
  const child = spawn(process.execPath, [cli, "--mode", "rpc", "--offline", "--no-session", "--approve", "--no-extensions", "--no-mcp", "-e", ".pi/extensions/pi-remote-debug.ts", "-e", ".pi/tests/fixtures/debug-provider.ts", "--provider", "pi-remote-debug-fixture", "--model", "local", "--tools", "pi_remote_debug_status,pi_remote_debug_capture,pi_remote_debug_interact"], { env: { ...process.env, HOME: f.home, PI_CODING_AGENT_DIR: join(f.home, ".pi", "agent") }, stdio: ["pipe", "pipe", "pipe"] });
  cleanup.push(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  const records: any[] = []; let buffer = "", stderr = "", rounds = 0;
  child.stderr.on("data", bytes => { stderr += bytes; });
  child.stdout.on("data", bytes => {
    buffer += bytes;
    while (buffer.includes("\n")) {
      const end = buffer.indexOf("\n"), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line) continue;
      const record = JSON.parse(line); records.push(record);
      if (record.type === "agent_settled") {
        if (++rounds === 1) child.stdin.write(JSON.stringify({ id: "reload", type: "prompt", message: "/debug-fixture-reload" }) + "\n");
        else child.stdin.end();
      }
      if (record.type === "response" && record.id === "reload") {
        if (record.success) child.stdin.write(JSON.stringify({ id: "after-reload", type: "prompt", message: "Run the local debug fixture again." }) + "\n");
        else child.stdin.end();
      }
    }
  });
  child.stdin.write(JSON.stringify({ id: "debug-fixture", type: "prompt", message: "Run the local debug fixture." }) + "\n");
  const code = await new Promise<number | null>((resolve, reject) => { child.once("error", reject); child.once("close", resolve); });
  assert.equal(code, 0, stderr);
  assert.ok(records.some(r => r.type === "agent_settled"));
  const tools = records.filter(r => r.type === "tool_execution_end");
  assert.equal(tools.length, 6);
  assert.deepEqual(tools.map(r => r.toolName).sort(), ["pi_remote_debug_capture", "pi_remote_debug_capture", "pi_remote_debug_interact", "pi_remote_debug_interact", "pi_remote_debug_status", "pi_remote_debug_status"]);
  assert.ok(records.some(r => r.type === "response" && r.id === "reload" && r.success));
  for (const tool of tools) { assert.equal(tool.isError, false); assert.ok(!JSON.stringify(tool).includes(token)); }
  const imageResult = tools.find(r => r.toolName === "pi_remote_debug_capture").result;
  assert.equal(imageResult.content[1].type, "image"); assert.equal(imageResult.content[1].mimeType, "image/png");
  assert.equal(f.requests.length, 6);
  for (const tool of tools.filter(r => r.toolName === "pi_remote_debug_interact")) assert.deepEqual(tool.result.structuredContent, { action: "navigate", outcome: "applied" });
  await assert.rejects(lstat(join(f.home, ".pi", "agent", "sessions")), { code: "ENOENT" });
});

test("installed ExtensionRunner creates real tui-mode tool contexts without a terminal renderer", async t => {
  const f = await fixture((r, s) => s.end(wire(r.id, r.operation === "status" ? status : r.operation === "interact" ? { action: r.interaction.action, outcome: "applied" } : capture())), true);
  const cli = await realpath(execFileSync("which", ["pi"], { encoding: "utf8" }).trim());
  const root = resolve(dirname(cli), "../..");
  const installed = (path: string) => import(pathToFileURL(join(root, "dist/core", path + ".js")).href);
  const [{ loadExtensions }, { ExtensionRunner }, { wrapRegisteredTool }, { SessionManager }, { ModelRuntime }, { ModelRegistry }] = await Promise.all([installed("extensions/loader"), installed("extensions/runner"), installed("extensions/wrapper"), installed("session-manager"), installed("model-runtime"), installed("model-registry")]);
  const home = process.env.HOME; process.env.HOME = f.home;
  let runner: any;
  try {
    const loaded = await loadExtensions([resolve(".pi/extensions/pi-remote-debug.ts")], process.cwd()); assert.deepEqual(loaded.errors, []);
    const models = await ModelRuntime.create({ authPath: join(f.home, "auth.json"), modelsPath: null, modelsStorePath: join(f.home, "model-cache.json"), allowModelNetwork: false, refreshOnCreate: false });
    runner = new ExtensionRunner(loaded.extensions, loaded.runtime, process.cwd(), SessionManager.inMemory(), new ModelRegistry(models));
    runner.setUIContext(undefined, "tui");
    await runner.emit({ type: "session_start", reason: "startup" });
    const contexts = t.mock.method(runner, "createToolContext");
    for (const registered of runner.getAllRegisteredTools()) {
      const tool = wrapRegisteredTool(registered, runner);
      const interaction = tool.name.endsWith("interact");
      const result = await tool.execute("real-tui-context", interaction ? { action: "sidebar", value: "show" } : {}, undefined, undefined);
      assert.equal(contexts.mock.calls.at(-1).result.mode, "tui");
      assert.equal(contexts.mock.calls.at(-1).result.hasUI, false);
      if (tool.name.endsWith("status")) assert.deepEqual(result.structuredContent, status);
      else if (interaction) assert.deepEqual(result.structuredContent, { action: "sidebar", outcome: "applied" });
      else assert.equal(result.content[1].mimeType, "image/png");
    }
    assert.equal(f.requests.length, 3);
    await runner.emit({ type: "session_shutdown", reason: "reload" });
    const old = wrapRegisteredTool(runner.getAllRegisteredTools()[0], runner);
    await assert.rejects(old.execute("after-shutdown", {}, undefined, undefined), { message: "Pi Remote debug request was cancelled." });
  } finally {
    if (runner) await runner.emit({ type: "session_shutdown", reason: "exit" });
    if (home === undefined) delete process.env.HOME; else process.env.HOME = home;
  }
});

test("factory has no endpoint I/O; tools return safe text/image/details without UI", async t => {
  const registered: any[] = []; const handlers = new Map<string, Function>();
  extension({ registerTool: (tool: any) => registered.push(tool), on: (event: string, handler: Function) => handlers.set(event, handler) } as any);
  assert.deepEqual(registered.map(tool => tool.name), ["pi_remote_debug_status", "pi_remote_debug_capture", "pi_remote_debug_interact"]);
  for (const tool of registered.slice(0, 2)) { assert.deepEqual(tool.parameters, { type: "object", properties: {}, required: [], additionalProperties: false }); assert.equal(tool.annotations.readOnlyHint, true); assert.ok(tool.outputSchema); }
  assert.deepEqual(registered[2].annotations, { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false });
  const request = t.mock.method(DebugClient.prototype, "request", async operation => operation === "status" ? validateStatus(status) : operation === "interact" ? { action: "type_text", outcome: "applied" } : validateCapture(capture()));
  for (const mode of ["tui", "rpc", "json", "print"]) {
    const statusResult = await registered[0].execute("id", {}, undefined, undefined, { mode });
    assert.deepEqual(JSON.parse(statusResult.content[0].text), status); assert.deepEqual(statusResult.details, status); assert.deepEqual(statusResult.structuredContent, status);
    const imageResult = await registered[1].execute("id", {}, undefined, undefined, { mode });
    assert.equal(imageResult.content[1].type, "image"); assert.deepEqual(imageResult.structuredContent.image, imageResult.content[1]);
    assert.deepEqual(JSON.parse(imageResult.content[0].text), imageResult.details); assert.ok(!JSON.stringify(imageResult).includes(token));
    const input = { action: "type_text", value: token };
    const interactionResult = await registered[2].execute("id", input, undefined, undefined, { mode });
    assert.deepEqual(request.mock.calls.at(-1)!.arguments, ["interact", undefined, input]);
    assert.deepEqual(interactionResult.structuredContent, { action: "type_text", outcome: "applied" });
    assert.deepEqual(interactionResult.details, interactionResult.structuredContent);
    assert.deepEqual(JSON.parse(interactionResult.content[0].text), interactionResult.structuredContent);
    assert.ok(!JSON.stringify(interactionResult).includes(token));
  }
  request.mock.restore();
  handlers.get("session_shutdown")!(); handlers.get("session_shutdown")!();
  await assert.rejects(registered[0].execute("id", {}, undefined), { message: "Pi Remote debug request was cancelled." });
  handlers.get("session_start")!();
  const controller = new AbortController(); controller.abort();
  await assert.rejects(registered[0].execute("id", {}, controller.signal), { message: "Pi Remote debug request was cancelled." });
  handlers.get("session_shutdown")!();
});
