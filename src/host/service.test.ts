import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { MemorySecrets, required, until } from "../fixtures/client.ts"
import { AppServer } from "./server.ts"
import { piEntry, Service, type ServiceOptions } from "./service.ts"
import { PrivateStorage } from "./storage.ts"

let root: string
const services: Service[] = []
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "pi-service-test-"))
  await mkdir(join(root, "projects"))
})
afterEach(async () => {
  for (const service of services.splice(0)) await service.stop()
  await rm(root, { recursive: true, force: true })
})
function options(): ServiceOptions {
  return {
    directory: join(root, "projects"),
    dataDirectory: join(root, "catalog"),
    address: "127.0.0.1",
    port: 0,
    pi: resolve("src/fixtures/fake-pi.ts"),
  }
}
async function start(value = options(), secrets = new MemorySecrets()): Promise<Service> {
  const service = await Service.start(value, { secrets })
  services.push(service)
  return service
}

test("startup has no active session, second writer is rejected, and stop releases catalog and port", async () => {
  const config = options(),
    secrets = new MemorySecrets()
  const first = await start(config, secrets)
  expect(first.coordinator.snapshot.sessions).toEqual([])
  expect(first.coordinator.snapshot.selected).toBeUndefined()
  expect(first.coordinator.snapshot.piVersion).not.toBe("Not running")
  await expect(Service.start(config, { secrets })).rejects.toMatchObject({ code: "catalogBusy" })
  const port = first.server.port
  await Promise.all([first.stop(), first.stop()])
  const rebound = Bun.serve({ hostname: "127.0.0.1", port, fetch: () => new Response("fixture") })
  await rebound.stop(true)
  const second = await start({ ...config, port }, secrets)
  expect(second.identity.der).toEqual(first.identity.der)
  expect(second.coordinator.snapshot.host).toBe(first.coordinator.snapshot.host)
  expect(second.coordinator.snapshot.selected).toBeUndefined()
})

test("secret-store startup failure releases the catalog without a plaintext fallback", async () => {
  const config = options()
  const secrets = new MemorySecrets()
  secrets.get = async () => {
    throw new Error("fixture locked secret service")
  }
  await expect(Service.start(config, { secrets })).rejects.toThrow("locked secret service")
  const reopened = await PrivateStorage.initialize(config.dataDirectory)
  try {
    expect(await reopened.readJSON("identity.json")).toBeNull()
    expect(await reopened.readJSON("devices.json")).toBeNull()
  } finally {
    reopened.close()
  }
  const recovered = await start(config)
  expect(recovered.server.running).toBe(true)
})

test("startup cancellation releases a catalog even when an injected OS store never responds", async () => {
  const config = options(),
    secrets = new MemorySecrets(),
    controller = new AbortController()
  secrets.get = async () => new Promise<Buffer | null>(() => {})
  const starting = Service.start(config, { secrets, signal: controller.signal })
  const timer = setTimeout(() => controller.abort(), 100)
  try {
    await expect(starting).rejects.toMatchObject({ code: "cancelled" })
  } finally {
    clearTimeout(timer)
  }
  const reopened = await PrivateStorage.initialize(config.dataDirectory)
  reopened.close()
})

test("startup cancellation reaps a blocked certificate generator before releasing the catalog", async () => {
  const config = options(),
    controller = new AbortController()
  const worker = join(root, "generator.ts"),
    pidFile = join(root, "generator.pid")
  await writeFile(
    worker,
    `await Bun.write(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(()=>{}, 1000);`,
  )
  const original = Bun.spawn
  const mocked = spyOn(Bun, "spawn").mockImplementation(((command: unknown, settings?: unknown) => {
    if (Array.isArray(command) && command[0] === "/usr/bin/openssl") {
      expect(command[command.indexOf("-keyout") + 1]).toBe(
        process.platform === "darwin" ? "/dev/stdout" : "-",
      )
      expect(settings).toHaveProperty("stdout", "pipe")
      return Reflect.apply(original, Bun, [[process.execPath, worker], settings])
    }
    return Reflect.apply(original, Bun, settings === undefined ? [command] : [command, settings])
  }) as typeof Bun.spawn)
  const starting = Service.start(config, {
    secrets: new MemorySecrets(),
    signal: controller.signal,
  })
  try {
    await until(() => existsSync(pidFile))
    const pid = Number(await Bun.file(pidFile).text()),
      before = performance.now()
    controller.abort()
    await expect(starting).rejects.toMatchObject({ code: "cancelled" })
    expect(() => process.kill(pid, 0)).toThrow()
    expect(performance.now() - before).toBeLessThan(2500)
    const reopened = await PrivateStorage.initialize(config.dataDirectory)
    reopened.close()
  } finally {
    controller.abort()
    await starting.catch(() => {})
    mocked.mockRestore()
  }
})

test("listener bind failure releases catalog and a later startup can use the same port", async () => {
  const occupied = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () => new Response("occupied"),
  })
  const config = { ...options(), port: required(occupied.port) },
    secrets = new MemorySecrets()
  try {
    await expect(Service.start(config, { secrets })).rejects.toThrow()
  } finally {
    await occupied.stop(true)
  }
  const recovered = await start(config, secrets)
  expect(recovered.server.port).toBe(config.port)
})

test("failed Pi version check releases catalog and leaves no listener", async () => {
  const bad = join(root, "bad-pi.ts")
  await writeFile(bad, "process.exit(7)\n")
  const config = options()
  await expect(
    Service.start({ ...config, pi: bad }, { secrets: new MemorySecrets() }),
  ).rejects.toMatchObject({ code: "piLaunchFailed" })
  const reopened = await PrivateStorage.initialize(config.dataDirectory)
  reopened.close()
  expect((await start(config)).server.running).toBe(true)
})

test("abort after listener creation releases both the listener and catalog", async () => {
  const config = options(),
    secrets = new MemorySecrets(),
    abort = new AbortController()
  const original = AppServer.start.bind(AppServer)
  let port = 0
  const listen = spyOn(AppServer, "start").mockImplementation(async (input) => {
    const result = await original(input)
    port = result.port
    abort.abort()
    return result
  })
  try {
    await expect(Service.start(config, { secrets, signal: abort.signal })).rejects.toThrow()
  } finally {
    listen.mockRestore()
  }
  expect(port).toBeGreaterThan(0)
  const recovered = await start({ ...config, port }, secrets)
  expect(recovered.server.port).toBe(port)
})

test("Pi entry selection rejects missing files and shell wrappers without invoking them", async () => {
  await expect(piEntry(join(root, "missing"))).rejects.toMatchObject({ code: "piLaunchFailed" })
  const shell = join(root, "pi")
  await writeFile(shell, "#!/bin/sh\nprintf must-not-run\n")
  await expect(piEntry(shell)).rejects.toMatchObject({ code: "piLaunchFailed" })
})
