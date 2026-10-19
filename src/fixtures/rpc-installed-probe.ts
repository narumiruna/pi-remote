// Explicit local probe. No provider prompt or user configuration writes.
import assert from "node:assert/strict"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { isAbsolute, join } from "node:path"
import { PiRPC } from "../host/rpc.ts"

const entry = process.argv[2]
assert(entry && isAbsolute(entry), "Supply the absolute installed Pi JavaScript entry")
const root = await mkdtemp(join(tmpdir(), "pi-remote-rpc-probe-"))
const cwd = join(root, "project ' ; $ directory")
await mkdir(cwd)
let rpc: PiRPC | undefined
try {
  rpc = await PiRPC.start({
    entry,
    cwd,
    args: [
      "--no-session",
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
    onEvent: () => {},
  })
  const state = (await rpc.request("get_state")) as Record<string, unknown>
  assert.equal(state.isStreaming, false)
  const messages = (await rpc.request("get_messages")) as Record<string, unknown>
  assert.deepEqual(messages.messages, [])
  await rpc.shutdown()
  let alive = false
  try {
    process.kill(rpc.childPid as number, 0)
    alive = true
  } catch {
    /* Confirmed absent. */
  }
  assert.equal(alive, false)
  console.log(
    "Installed Pi RPC probe passed: Bun launch, empty PATH, no prompts, child exit confirmed.",
  )
} finally {
  await rpc?.shutdown()
  await rm(root, { recursive: true, force: true })
}
