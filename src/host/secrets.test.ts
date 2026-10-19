import { expect, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { OSSecrets, type SecretStore } from "./secrets.ts"

/** Test fixture only. There is no memory-secret production option. */
export class MemorySecrets implements SecretStore {
  private readonly values = new Map<string, Buffer>()
  async get(account: string): Promise<Buffer | null> {
    const data = this.values.get(account)
    return data === undefined ? null : Buffer.from(data)
  }
  async put(account: string, data: Buffer): Promise<void> {
    this.values.set(account, Buffer.from(data))
  }
  async remove(account: string): Promise<void> {
    this.values.delete(account)
  }
}

test("test-only memory secrets copy binary values and support idempotent removal", async () => {
  const store = new MemorySecrets()
  expect(await store.get("missing")).toBeNull()
  const bytes = Buffer.from([0, 255, 1])
  await store.put("account", bytes)
  bytes[0] = 2
  const first = await store.get("account")
  expect(first).toEqual(Buffer.from([0, 255, 1]))
  if (first) first[0] = 3
  expect(await store.get("account")).toEqual(Buffer.from([0, 255, 1]))
  await store.remove("account")
  await store.remove("account")
  expect(await store.get("account")).toBeNull()
})

for (const action of ["abort", "deadline"] as const) {
  test(`an unresponsive native secret worker is killable by ${action}`, async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-secret-worker-"))
    const entry = join(root, "hang.ts"),
      pidFile = join(root, "pid")
    await writeFile(
      entry,
      `await Bun.write(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(()=>{}, 1000); await Bun.stdin.arrayBuffer();\n`,
    )
    const controller = new AbortController(),
      store = new OSSecrets(randomUUID(), controller.signal)
    ;(store as unknown as { workerEntry: string }).workerEntry = entry
    const pending = store.get("fixture-account")
    const before = performance.now()
    try {
      for (let attempt = 0; attempt < 200 && !(await Bun.file(pidFile).exists()); attempt++)
        await Bun.sleep(5)
      const pid = Number(await Bun.file(pidFile).text())
      if (action === "abort") controller.abort()
      await expect(pending).rejects.toMatchObject({ code: "secretStoreUnavailable" })
      await store.close()
      expect(() => process.kill(pid, 0)).toThrow()
      expect(performance.now() - before).toBeLessThan(action === "abort" ? 1500 : 7000)
    } finally {
      await store.close()
      await rm(root, { recursive: true, force: true })
    }
  }, 10_000)
}

test("OS secret services are scoped by catalog UUID", () => {
  const id = randomUUID()
  const first = new OSSecrets(id)
  expect(new OSSecrets(id.toUpperCase()).service).toBe(first.service)
  expect(new OSSecrets(randomUUID()).service).not.toBe(first.service)
  expect(() => new OSSecrets("not-a-catalog")).toThrow()
})

test("OS secret input checks do not access the real store", async () => {
  const store = new OSSecrets(randomUUID())
  await expect(store.get("\0")).rejects.toMatchObject({ code: "invalidRequest" })
  await expect(store.remove("")).rejects.toMatchObject({ code: "invalidRequest" })
  await expect(store.put("account", Buffer.alloc(1024 * 1024 + 1))).rejects.toMatchObject({
    code: "secretLimit",
  })
})

test("keyring 2.1.2 native addon loads on Bun without accessing credentials", async () => {
  const { AsyncEntry } = await import("@napi-rs/keyring")
  expect(typeof AsyncEntry).toBe("function")
})

test.skipIf(process.platform !== "linux")(
  "Linux fails closed when the D-Bus Secret Service is unavailable",
  async () => {
    const source = `import {OSSecrets} from ${JSON.stringify(new URL("./secrets.ts", import.meta.url).href)}; try {await new OSSecrets(${JSON.stringify(randomUUID())}).get("unavailable-store-probe"); process.exit(2)} catch(e) {if(e.code!=="secretStoreUnavailable" || !e.message.includes("Secret Service")) process.exit(3);}`
    const child = Bun.spawn([process.execPath, "-e", source], {
      env: {
        ...process.env,
        DBUS_SESSION_BUS_ADDRESS: "unix:path=/nonexistent/pi-remote-no-session-bus",
        DBUS_SYSTEM_BUS_ADDRESS: "unix:path=/nonexistent/pi-remote-no-system-bus",
      },
      stdout: "ignore",
      stderr: "ignore",
    })
    expect(await child.exited).toBe(0)
  },
  15_000,
)

// Explicit opt-in only. Uses a fresh UUID service and removes its sole test account.
test.skipIf(process.env.PI_REMOTE_TEST_OS_SECRETS !== "1")(
  "isolated OS secret binary roundtrip, restart lookup and catalog isolation",
  async () => {
    const id = randomUUID()
    const first = new OSSecrets(id)
    const second = new OSSecrets(id)
    try {
      expect(await first.get("isolated-binary-test")).toBeNull()
      const bytes = Buffer.from([0, 1, 255, 2, 0])
      await first.put("isolated-binary-test", bytes)
      expect(await second.get("isolated-binary-test")).toEqual(bytes)
      const source = `import {OSSecrets} from ${JSON.stringify(new URL("./secrets.ts", import.meta.url).href)}; const actual=await new OSSecrets(${JSON.stringify(id)}).get("isolated-binary-test"); const expected=Buffer.from(await Bun.stdin.arrayBuffer()); process.exit(actual?.equals(expected) ? 0 : 2);`
      const child = Bun.spawn([process.execPath, "-e", source], {
        stdin: "pipe",
        stdout: "ignore",
        stderr: "ignore",
      })
      child.stdin.write(bytes)
      child.stdin.end()
      expect(await child.exited).toBe(0)
      expect(await new OSSecrets(randomUUID()).get("isolated-binary-test")).toBeNull()
      await second.remove("isolated-binary-test")
      expect(await first.get("isolated-binary-test")).toBeNull()
      await first.remove("isolated-binary-test")
    } finally {
      await first.remove("isolated-binary-test")
    }
  },
  30_000,
)
