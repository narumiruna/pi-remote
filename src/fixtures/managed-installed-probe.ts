// Provider-free installed-Pi lifecycle probe. All files and settings are isolated.
import assert from "node:assert/strict"
import { randomUUID } from "node:crypto"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { isAbsolute, join } from "node:path"
import type { PiRPC } from "../host/rpc.ts"
import { Service } from "../host/service.ts"
import { MemorySecrets } from "./client.ts"

const entry = process.argv[2]
assert(entry && isAbsolute(entry), "Supply the absolute installed Pi JavaScript entry")
const root = await mkdtemp(join(tmpdir(), "pi-managed-probe-"))
const directory = join(root, "projects", "project ' ; $ directory")
await mkdir(directory, { recursive: true })
let service: Service | undefined
try {
  service = await Service.start(
    { directory, dataDirectory: join(root, "catalog"), address: "127.0.0.1", port: 0, pi: entry },
    {
      secrets: new MemorySecrets(),
      piArgs: [
        "--offline",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-themes",
        "--no-context-files",
        "--no-tools",
      ],
      env: {
        PI_CODING_AGENT_DIR: join(root, "agent"),
        PI_OFFLINE: "1",
        PI_SKIP_VERSION_CHECK: "1",
        PI_TELEMETRY: "0",
        PATH: "",
      },
    },
  )
  const host = service.coordinator
  const send = (action: string, fields: Record<string, unknown> = {}) =>
    host.handle(
      {
        kind: "request",
        id: randomUUID().toUpperCase(),
        epoch: host.snapshot.epoch,
        session: host.snapshot.selected,
        action,
        fields,
      },
      randomUUID().toUpperCase(),
      () => true,
    )
  assert.equal(host.snapshot.selected, undefined)
  const page = await host.directories.list()
  assert.deepEqual(await send("createSession", { directory: page.id }), { ok: {} })
  const id = host.snapshot.selected
  assert(id)
  const rpc = (host as unknown as { child: PiRPC }).child
  // Persist a benign session-info entry without a model request.
  await rpc.request("set_session_name", { name: "Isolated CLI lifecycle probe" })
  assert.deepEqual(await send("closeSession"), { ok: {} })
  assert.deepEqual(await send("resumeSession", { id }), { ok: {} })
  assert.equal(host.snapshot.selected, id)
  assert.equal(host.snapshot.phase, "idle")
  assert.deepEqual(host.snapshot.messages, [])
  assert.deepEqual(await send("stop"), { ok: {} })
  await service.stop()
  console.log(
    "PASS: installed Pi managed creation, persistence, explicit resume and cleanup on Bun; no provider prompts.",
  )
} finally {
  await service?.stop()
  await rm(root, { recursive: true, force: true })
}
