// No provider, session, history, or image files. This probe loads the actual
// installed Pi extension factory and calls its registered tool definition.
// It does not claim to exercise a live interactive or RPC session.
// HOME=<app CFFIXED_USER_HOME> node .pi/tests/debug-probe.ts status|capture
// HOME=<app CFFIXED_USER_HOME> node .pi/tests/debug-probe.ts interact ACTION VALUE
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { realpath } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { inflateSync } from "node:zlib";

function meanLuminance(png: Buffer): number {
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  const channels = png[25] === 6 ? 4 : png[25] === 2 ? 3 : 0;
  if (png[24] !== 8 || !channels || png[28] !== 0) throw new Error("Luminance probe needs a non-interlaced 8-bit RGB or RGBA PNG.");
  const chunks: Buffer[] = [];
  for (let offset = 8; offset < png.length;) {
    const size = png.readUInt32BE(offset);
    if (png.toString("ascii", offset + 4, offset + 8) === "IDAT") chunks.push(png.subarray(offset + 8, offset + 8 + size));
    offset += size + 12;
  }
  const stride = width * channels;
  const raw = inflateSync(Buffer.concat(chunks), { maxOutputLength: (stride + 1) * height });
  let previous = Buffer.alloc(stride), total = 0;
  const paeth = (a: number, b: number, c: number) => {
    const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  };
  for (let y = 0; y < height; y++) {
    const start = y * (stride + 1), filter = raw[start];
    const row = Buffer.from(raw.subarray(start + 1, start + 1 + stride));
    for (let x = 0; x < stride; x++) {
      const left = x >= channels ? row[x - channels] : 0;
      const up = previous[x], upperLeft = x >= channels ? previous[x - channels] : 0;
      row[x] = (row[x] + (filter === 1 ? left : filter === 2 ? up : filter === 3 ? Math.floor((left + up) / 2) : filter === 4 ? paeth(left, up, upperLeft) : 0)) & 255;
    }
    for (let x = 0; x < stride; x += channels) total += 0.2126 * row[x] + 0.7152 * row[x + 1] + 0.0722 * row[x + 2];
    previous = row;
  }
  return Math.round(total / (width * height) * 1000) / 1000;
}

const operation = process.argv[2];
if (!["status", "capture", "interact"].includes(operation) || process.argv.length !== (operation === "interact" ? 5 : 3)) {
  console.error("Usage: node .pi/tests/debug-probe.ts status|capture OR interact ACTION VALUE"); process.exitCode = 2;
} else {
  const cli = await realpath(execFileSync("which", ["pi"], { encoding: "utf8" }).trim());
  const root = resolve(dirname(cli), "../..");
  const { loadExtensions } = await import(pathToFileURL(join(root, "dist/core/extensions/loader.js")).href);
  const cwd = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const loaded = await loadExtensions([join(cwd, ".pi/extensions/pi-remote-debug.ts")], cwd);
  if (loaded.errors.length || loaded.extensions.length !== 1) {
    console.log(JSON.stringify({ ok: false, error: "Pi extension loading failed." })); process.exitCode = 1;
  } else {
    const extension = loaded.extensions[0];
    try {
      const tool = extension.tools.get(`pi_remote_debug_${operation}`)!.definition;
      const params = operation === "interact" ? { action: process.argv[3], value: process.argv[4] } : {};
      const result = await tool.execute("local-probe", params, undefined, undefined, undefined);
      if (operation === "interact") console.log(JSON.stringify({ ok: true, ...result.structuredContent }));
      else if (operation === "status") console.log(JSON.stringify({ ok: true, status: result.structuredContent }));
      else {
        const capture = result.structuredContent as { image: { data: string }; metadata: Record<string, unknown> };
        const png = Buffer.from(capture.image.data, "base64");
        console.log(JSON.stringify({ ok: true, ...capture.metadata, pngBytes: png.length, sha256: createHash("sha256").update(png).digest("hex"), meanLuminance: meanLuminance(png) }));
      }
    } catch (error) {
      // The extension reports only fixed, safe errors. Do not print stacks or
      // caught parser/transport objects from other components.
      const fixedMessages = new Set([
        "Capture is blocked while a protected surface is visible.",
        "The Pi Remote window is unavailable. Show the main window and try again.",
        "The Pi Remote window selection is ambiguous.",
      ]);
      const text = error instanceof Error && (error.message.startsWith("Pi Remote") || fixedMessages.has(error.message))
        ? error.message : "Debug probe failed.";
      console.log(JSON.stringify({ ok: false, error: text })); process.exitCode = 1;
    } finally {
      for (const handler of extension.handlers.get("session_shutdown") ?? []) await handler({ type: "session_shutdown", reason: "exit" }, {});
    }
  }
}
