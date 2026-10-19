// Test-only harness. It is not part of the npm artifact or CLI arguments.
import { copyFile, mkdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import type { SecretStore } from "../host/secrets.ts"
import { OSSecrets } from "../host/secrets.ts"
import { Service } from "../host/service.ts"
import { PrivateStorage } from "../host/storage.ts"

class FixtureSecrets implements SecretStore {
  private values = new Map<string, Buffer>()
  async get(account: string) {
    return this.values.get(account) ?? null
  }
  async put(account: string, value: Buffer) {
    this.values.set(account, Buffer.from(value))
  }
  async remove(account: string) {
    this.values.delete(account)
  }
}

const evidence = resolve(process.argv[2] ?? "/tmp/pi-remote-cli-simulator-fixture")
const root = resolve(process.env.CLI_FIXTURE_ROOT ?? evidence)
const visibleEvidence = process.env.CLI_FIXTURE_EVIDENCE_HOST ?? evidence
const address = process.argv[3] ?? "127.0.0.1"
let port = Number(process.argv[4] ?? "0")
const advertise = process.argv[5] ?? address
const directory = join(root, "projects")
const controlDirectory = join(evidence, "control")
await mkdir(join(directory, "project"), { recursive: true, mode: 0o700 })
await mkdir(controlDirectory, { recursive: true, mode: 0o700 })
await mkdir(join(root, "state"), { recursive: true, mode: 0o700 })
const secrets: SecretStore = new FixtureSecrets()
let osCatalogID: string | undefined
if (process.env.PI_REMOTE_TEST_OS_SECRETS === "1") {
  const storage = await PrivateStorage.initialize(join(root, "state"))
  osCatalogID = storage.catalogID
  storage.close()
}
let service: Service | undefined
let stopping = false
for (const signal of ["SIGINT", "SIGTERM"] as const)
  process.on(signal, () => {
    stopping = true
  })
const atomic = async (path: string, value: unknown) => {
  const temporary = `${path}.tmp`
  await writeFile(temporary, JSON.stringify(value), { mode: 0o600 })
  await rename(temporary, path)
}
const consume = async (name: string): Promise<Record<string, unknown> | undefined> => {
  const path = join(controlDirectory, name)
  try {
    const data = await readFile(path)
    if (data.length > 4096) throw new Error("Oversized fixture control")
    await rm(path)
    return JSON.parse(data.toString("utf8")) as Record<string, unknown>
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined
    throw error
  }
}
async function start() {
  const host = await Service.start(
    {
      directory,
      dataDirectory: join(root, "state"),
      address,
      port,
      pi: resolve(import.meta.dir, "fake-pi.ts"),
    },
    { secrets: osCatalogID ? new OSSecrets(osCatalogID) : secrets },
  )
  port = host.server.port
  return host
}
try {
  service = await start()
  const code = JSON.parse(
    Buffer.from(
      service.server.pairingCode(service.identity, advertise, "CLI acceptance fixture"),
      "base64",
    ).toString("utf8"),
  )
  code.url = `wss://${advertise}:${port}/`
  await atomic(join(evidence, "config.json"), {
    pairingCode: Buffer.from(JSON.stringify(code)).toString("base64"),
    cwd: await realpath(directory),
    controlDirectory: join(visibleEvidence, "control"),
    outputFile: join(visibleEvidence, "result.json"),
    verificationFile: join(visibleEvidence, "acceptance.txt"),
  })
  console.log("READY: private CLI acceptance fixture")
  let approvedDevice: string | undefined
  const deadline = Date.now() + 15 * 60_000
  while (!stopping && Date.now() < deadline) {
    const approve = await consume("approve.json")
    if (approve) approvedDevice = String(approve.device).toUpperCase()
    const pending = service.server.pendingPair
    if (pending && approvedDevice) {
      if (pending.device.id === approvedDevice) await service.server.approve(pending.id)
      else service.server.deny(pending.id)
      approvedDevice = undefined
    }
    const revoke = await consume("revoke.json")
    if (revoke) {
      await service.server.revoke(String(revoke.device).toUpperCase())
      await atomic(join(controlDirectory, "revoke.done"), {})
    }
    if (await consume("restart.json")) {
      await service.stop()
      service = await start()
      await atomic(join(controlDirectory, "restart.done"), {})
    }
    try {
      await copyFile(join(directory, "project", "acceptance.txt"), join(evidence, "acceptance.txt"))
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error
    }
    if (await Bun.file(join(evidence, "result.json")).exists()) stopping = true
    await Bun.sleep(20)
  }
  if (!stopping) throw new Error("Fixture deadline")
} catch {
  console.error(
    "FAIL: CLI acceptance fixture. Inspect isolated test checks; no private output retained.",
  )
  process.exitCode = 1
} finally {
  await service?.stop()
}
