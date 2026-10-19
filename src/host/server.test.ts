import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import { randomBytes, randomUUID } from "node:crypto"
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { MemorySecrets, required, TestClient, until } from "../fixtures/client.ts"
import { Coordinator } from "./coordinator.ts"
import { DirectoryAccess } from "./directories.ts"
import { IdentityStore, type TLSIdentity } from "./identity.ts"
import { AppServer } from "./server.ts"
import { PrivateStorage } from "./storage.ts"

let root: string
let storage: PrivateStorage
let coordinator: Coordinator
let server: AppServer
let identity: TLSIdentity
let secrets: MemorySecrets
const clients: TestClient[] = []
const device = () => randomUUID().toUpperCase()

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "pi-wss-test-"))
  const directory = join(root, "src")
  await mkdir(directory)
  storage = await PrivateStorage.initialize(join(root, "catalog"))
  secrets = new MemorySecrets()
  identity = await new IdentityStore(secrets, storage).loadOrCreate(["127.0.0.1"])
  coordinator = await Coordinator.open({
    storage,
    directories: new DirectoryAccess(directory),
    entry: resolve("src/fixtures/fake-pi.ts"),
  })
  server = await AppServer.start({
    storage,
    coordinator,
    secrets,
    identity,
    address: "127.0.0.1",
    port: 0,
  })
})
afterEach(async () => {
  for (const client of clients.splice(0)) client.close()
  await server?.stop()
  await coordinator?.shutdown()
  await rm(root, { recursive: true, force: true })
})
function connect(pin = identity, hostname?: string): TestClient {
  const client = new TestClient(server.port, pin, hostname)
  clients.push(client)
  return client
}
async function pair(id = device()): Promise<{ id: string; credential: Buffer }> {
  const grant = server.openPairing()
  const client = connect()
  await client.wait("challenge")
  client.send({ pair: { device: id, name: "Integration phone", grant: grant.toString("base64") } })
  await client.wait("approvalRequired")
  expect(server.listDevices()).toEqual([])
  await server.approve(required(server.pendingPair).id)
  const paired = await client.wait("paired")
  await client.closed
  return { id, credential: Buffer.from(required(paired.credential), "base64") }
}

test("pinned WSS rejects a changed certificate and a hostname mismatch", async () => {
  const otherStorage = await PrivateStorage.initialize(join(root, "other"))
  try {
    const other = await new IdentityStore(new MemorySecrets(), otherStorage).loadOrCreate([
      "127.0.0.1",
    ])
    await expect(connect(other).wait("challenge")).rejects.toThrow()
    expect(() => connect(identity, "wrong.example")).toThrow("hostname mismatch")
    expect((await connect().wait("challenge")).nonce).toBeString()
  } finally {
    otherStorage.close()
  }
})

for (const content of ["x", "\t"]) {
  test("full permitted history remains readable through heartbeat and reconnection", async () => {
    const paired = await pair()
    coordinator.snapshot.messages = Array.from({ length: 32 }, () => ({
      id: randomUUID().toUpperCase(),
      role: "user",
      text: content.repeat(65536),
      isError: false,
      streaming: false,
      truncated: false,
    }))
    for (let attempt = 0; attempt < 2; attempt++) {
      const client = connect()
      await client.authenticate(paired.id, paired.credential)
      const authenticated = await client.wait("authenticated")
      client.request(required(authenticated.epoch), "snapshot")
      const reply = await client.wait("reply")
      expect(reply.state).toBeUndefined()
      expect(reply.result).toHaveProperty("snapshot._0.hasOlderMessages", true)
      client.close()
      await client.closed
    }
  })
}

test("unauthenticated requests never reach directory access or the coordinator", async () => {
  const handle = spyOn(coordinator, "handle")
  const listing = spyOn(coordinator.directories, "list")
  try {
    const client = connect()
    await client.wait("challenge")
    client.request(coordinator.snapshot.epoch, "directories")
    await client.closed
    expect(handle).not.toHaveBeenCalled()
    expect(listing).not.toHaveBeenCalled()
    expect(coordinator.snapshot.sessions).toEqual([])
  } finally {
    handle.mockRestore()
    listing.mockRestore()
  }
})

test("pairing needs a live grant and request-bound local approval", async () => {
  const noGrant = connect()
  await noGrant.wait("challenge")
  noGrant.send({
    pair: { device: device(), name: "Phone", grant: randomBytes(32).toString("base64") },
  })
  await noGrant.closed
  expect(server.pendingPair).toBeUndefined()
  const grant = server.openPairing()
  const client = connect()
  await client.wait("challenge")
  client.send({ pair: { device: device(), name: "Phone", grant: grant.toString("base64") } })
  await client.wait("approvalRequired")
  const pending = required(server.pendingPair)
  await expect(server.approve(device())).rejects.toMatchObject({ code: "expired" })
  expect(() => server.deny(device())).toThrow()
  expect(server.pendingPair).toEqual(pending)
  expect(server.listDevices()).toEqual([])
  client.request(coordinator.snapshot.epoch, "directories")
  await client.closed
  expect(server.pendingPair).toBeUndefined()
  await expect(server.approve(pending.id)).rejects.toMatchObject({ code: "expired" })
})

test("wrong and stale grants fail; denial and cancellation clear pending approval", async () => {
  const stale = server.openPairing()
  const grant = server.openPairing()
  for (const bytes of [randomBytes(32), stale]) {
    const client = connect()
    await client.wait("challenge")
    client.send({ pair: { device: device(), name: "Phone", grant: bytes.toString("base64") } })
    await client.closed
  }
  const denied = connect()
  await denied.wait("challenge")
  denied.send({ pair: { device: device(), name: "Phone", grant: grant.toString("base64") } })
  await denied.wait("approvalRequired")
  const old = required(server.pendingPair).id
  server.deny(old)
  await denied.wait("denied")
  await expect(server.approve(old)).rejects.toMatchObject({ code: "expired" })
  const next = server.openPairing()
  const cancelled = connect()
  await cancelled.wait("challenge")
  cancelled.send({ pair: { device: device(), name: "Phone", grant: next.toString("base64") } })
  await cancelled.wait("approvalRequired")
  const cancelledID = required(server.pendingPair).id
  server.closePairing()
  await cancelled.closed
  await expect(server.approve(cancelledID)).rejects.toMatchObject({ code: "expired" })
  expect(server.listDevices()).toEqual([])
})

test("pairing expires and rate-limits attempts even with a valid final code", async () => {
  const start = performance.now()
  const clock = spyOn(performance, "now")
  try {
    clock.mockReturnValue(start)
    const expired = server.openPairing()
    clock.mockReturnValue(start + 120_001)
    const client = connect()
    await client.wait("challenge")
    client.send({ pair: { device: device(), name: "Phone", grant: expired.toString("base64") } })
    await client.closed
    clock.mockReturnValue(start + 120_002)
    const grant = server.openPairing()
    for (let attempt = 0; attempt < 6; attempt++) {
      const peer = connect()
      await peer.wait("challenge")
      peer.send({
        pair: {
          device: device(),
          name: "Phone",
          grant: (attempt === 5 ? grant : randomBytes(32)).toString("base64"),
        },
      })
      await peer.closed
    }
    expect(server.pendingPair).toBeUndefined()
  } finally {
    clock.mockRestore()
  }
})

test("local approval cannot complete after the pending request expires", async () => {
  const now = performance.now()
  const clock = spyOn(performance, "now").mockReturnValue(now)
  try {
    const grant = server.openPairing()
    const client = connect()
    await client.wait("challenge")
    client.send({ pair: { device: device(), name: "Phone", grant: grant.toString("base64") } })
    await client.wait("approvalRequired")
    const pending = required(server.pendingPair)
    clock.mockReturnValue(now + 120_001)
    await expect(server.approve(pending.id)).rejects.toMatchObject({ code: "expired" })
    expect(server.listDevices()).toEqual([])
    expect(secrets.values.has(pending.device.id)).toBe(false)
  } finally {
    clock.mockRestore()
  }
})

test("authentication binds fresh nonce and canonical UUID; reconnect can browse", async () => {
  const paired = await pair()
  const first = connect()
  const nonce = required((await first.wait("challenge")).nonce)
  await first.authenticate(paired.id.toLowerCase(), paired.credential, paired.id, nonce)
  const auth = await first.wait("authenticated")
  expect(auth.epoch).toBe(coordinator.snapshot.epoch)
  first.request(required(auth.epoch), "directories")
  const reply = await first.wait("reply")
  expect(reply.result).toMatchObject({
    directories: { _0: { path: await realpath(join(root, "src")) } },
  })
  first.close()
  await first.closed
  const replay = connect()
  await replay.wait("challenge")
  await replay.authenticate(paired.id, paired.credential, paired.id, nonce)
  await replay.closed
  const wrongCaseProof = connect()
  await wrongCaseProof.authenticate(
    paired.id.toLowerCase(),
    paired.credential,
    paired.id.toLowerCase(),
  )
  await wrongCaseProof.closed
  const reconnect = connect()
  await reconnect.authenticate(paired.id, paired.credential)
  await reconnect.wait("authenticated")
  expect(server.listDevices()).toMatchObject([{ id: paired.id, connected: true }])
})

test("revocation closes live sockets and rejects credentials on reconnect", async () => {
  const paired = await pair()
  const live = connect()
  await live.authenticate(paired.id, paired.credential)
  await live.wait("authenticated")
  const directory = await coordinator.directories.list()
  live.request(coordinator.snapshot.epoch, "createSession", { directory: directory.id })
  expect((await live.wait("reply")).result).toEqual({ ok: {} })
  live.request(
    coordinator.snapshot.epoch,
    "prompt",
    { text: "CLI fixture: wait for Stop", delivery: "prompt" },
    required(coordinator.snapshot.selected),
  )
  expect((await live.wait("reply")).result).toEqual({ ok: {} })
  await until(() => coordinator.snapshot.phase === "working")
  await server.revoke(paired.id)
  await live.closed
  expect(server.listDevices()).toEqual([])
  expect(coordinator.snapshot.phase).toBe("working")
  const rejected = connect()
  await rejected.authenticate(paired.id, paired.credential)
  await rejected.closed
})

test("failed secret removal still revokes access after listener restart", async () => {
  const paired = await pair()
  const live = connect()
  await live.authenticate(paired.id, paired.credential)
  await live.wait("authenticated")
  secrets.failRemove = true
  await expect(server.revoke(paired.id)).rejects.toMatchObject({ code: "storageFailure" })
  await live.closed
  expect(server.running).toBe(false)
  expect(secrets.values.has(paired.id)).toBe(true)
  server = await AppServer.start({
    storage,
    coordinator,
    secrets,
    identity,
    address: "127.0.0.1",
    port: 0,
  })
  const rejected = connect()
  await rejected.authenticate(paired.id, paired.credential)
  await rejected.closed
  expect(server.listDevices()).toEqual([])
})

test("WSS coding survives disconnect; duplicate prompt does not write twice", async () => {
  const paired = await pair()
  const client = connect()
  await client.authenticate(paired.id, paired.credential)
  await client.wait("authenticated")
  client.request(coordinator.snapshot.epoch, "directories")
  const directories = await client.wait("reply")
  const page = directories.result as { directories: { _0: { id: string } } }
  client.request(coordinator.snapshot.epoch, "createSession", { directory: page.directories._0.id })
  expect((await client.wait("reply")).result).toEqual({ ok: {} })
  const session = required(coordinator.snapshot.selected)
  const text = "CLI fixture: write acceptance.txt with CLI acceptance\n"
  const id = client.request(
    coordinator.snapshot.epoch,
    "prompt",
    { text, delivery: "prompt" },
    session,
  )
  expect((await client.wait("reply")).result).toEqual({ ok: {} })
  client.close()
  await client.closed
  await until(() => coordinator.snapshot.phase === "idle")
  const reconnect = connect()
  await reconnect.authenticate(paired.id, paired.credential)
  await reconnect.wait("authenticated")
  reconnect.request(coordinator.snapshot.epoch, "prompt", { text, delivery: "prompt" }, session, id)
  expect((await reconnect.wait("reply")).result).toEqual({ ok: {} })
  expect(await Bun.file(join(root, "src", "acceptance.txt")).text()).toBe("CLI acceptance\n")
  expect(coordinator.snapshot.messages.filter((message) => message.role === "user")).toHaveLength(1)
})
