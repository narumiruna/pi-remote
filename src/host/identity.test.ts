import { afterEach, beforeEach, expect, spyOn, test } from "bun:test"
import { createPrivateKey, X509Certificate } from "node:crypto"
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { connect } from "node:tls"
import { IdentityStore } from "./identity.ts"
import { MemorySecrets } from "./secrets.test.ts"
import type { SecretStore } from "./secrets.ts"
import { PrivateStorage } from "./storage.ts"

let root: string
let storage: PrivateStorage
let secrets: MemorySecrets
beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "pi-identity-test-"))
  storage = await PrivateStorage.initialize(join(root, "catalog"))
  secrets = new MemorySecrets()
})
afterEach(() => {
  storage.close()
  rmSync(root, { recursive: true, force: true })
})

test("creates persistent TLS identity in injected secrets and only public fingerprint metadata", async () => {
  const first = await new IdentityStore(secrets, storage).loadOrCreate([
    "127.0.0.1",
    "192.168.1.10",
    "127.0.0.1",
  ])
  const certificate = new X509Certificate(first.cert)
  expect(certificate.raw.equals(first.der)).toBe(true)
  expect(certificate.checkIP("127.0.0.1")).toBe("127.0.0.1")
  expect(certificate.checkIP("192.168.1.10")).toBe("192.168.1.10")
  expect(certificate.checkIP("192.168.1.11")).toBeUndefined()
  expect(certificate.checkPrivateKey(createPrivateKey(first.key))).toBe(true)
  expect(Date.parse(certificate.validTo)).toBeGreaterThan(Date.now())
  const id = storage.catalogID
  storage.close()
  storage = await PrivateStorage.initialize(join(root, "catalog"))
  expect(storage.catalogID).toBe(id)
  const restored = await new IdentityStore(secrets, storage).loadOrCreate(["127.0.0.1"])
  expect(restored.der).toEqual(first.der)
  expect(restored.key).toBe(first.key)
  expect(readdirSync(storage.path).sort()).toEqual(["catalog-id.json", "identity.json"])
  const metadata = readFileSync(join(storage.path, "identity.json"), "utf8")
  expect(metadata).not.toContain("PRIVATE")
  expect(metadata).not.toContain(first.key)
  expect(Object.keys(JSON.parse(metadata)).sort()).toEqual(["sha256", "version"])
})

test("new addresses never silently replace the certificate", async () => {
  const store = new IdentityStore(secrets, storage)
  const first = await store.loadOrCreate(["127.0.0.1"])
  const saved = await secrets.get("tls-identity-v1")
  await expect(store.loadOrCreate(["192.168.1.2"])).rejects.toMatchObject({
    code: "identityAddressMismatch",
  })
  expect(await secrets.get("tls-identity-v1")).toEqual(saved)
  expect((await store.loadOrCreate(["127.0.0.1"])).der).toEqual(first.der)
})

test("corrupt secret schema, DER, PEM and key do not trigger replacement", async () => {
  const store = new IdentityStore(secrets, storage)
  await store.loadOrCreate(["127.0.0.1"])
  const original = await secrets.get("tls-identity-v1")
  if (!original) throw new Error("missing test fixture")
  const parsed = JSON.parse(original.toString("utf8"))
  for (const bad of [
    Buffer.from("not JSON"),
    Buffer.from(JSON.stringify({ ...parsed, version: 2 })),
    Buffer.from(JSON.stringify({ ...parsed, der: "AA==" })),
    Buffer.from(JSON.stringify({ ...parsed, cert: "invalid" })),
    Buffer.from(JSON.stringify({ ...parsed, key: "invalid" })),
    Buffer.from(JSON.stringify({ ...parsed, addresses: ["192.168.1.1"] })),
  ]) {
    await secrets.put("tls-identity-v1", bad)
    await expect(store.loadOrCreate(["127.0.0.1"])).rejects.toMatchObject({
      code: "corruptIdentity",
    })
    expect(await secrets.get("tls-identity-v1")).toEqual(bad)
  }
  await secrets.put("tls-identity-v1", original)
  await expect(store.loadOrCreate(["127.0.0.1"])).resolves.toHaveProperty("cert")
})

test("missing OS secret with existing metadata fails without creating a new identity", async () => {
  const store = new IdentityStore(secrets, storage)
  await store.loadOrCreate(["127.0.0.1"])
  await secrets.remove("tls-identity-v1")
  await expect(store.loadOrCreate(["127.0.0.1"])).rejects.toMatchObject({ code: "missingIdentity" })
  expect(await secrets.get("tls-identity-v1")).toBeNull()
  expect(readdirSync(storage.path).some((name) => name.startsWith("identity-scratch-"))).toBe(false)
})

test("changed valid certificate is rejected against catalog fingerprint", async () => {
  const original = await new IdentityStore(secrets, storage).loadOrCreate(["127.0.0.1"])
  const alternateStorage = await PrivateStorage.initialize(join(root, "alternate"))
  const alternateSecrets = new MemorySecrets()
  try {
    await new IdentityStore(alternateSecrets, alternateStorage).loadOrCreate(["127.0.0.1"])
    const replacement = await alternateSecrets.get("tls-identity-v1")
    if (!replacement) throw new Error("missing test fixture")
    await secrets.put("tls-identity-v1", replacement)
    await expect(
      new IdentityStore(secrets, storage).loadOrCreate(["127.0.0.1"]),
    ).rejects.toMatchObject({ code: "changedIdentity" })
    expect(await secrets.get("tls-identity-v1")).toEqual(replacement)
    expect(new X509Certificate(JSON.parse(replacement.toString()).cert).raw).not.toEqual(
      original.der,
    )
  } finally {
    alternateStorage.close()
  }
})

test("secret-store denial is returned before generation or disk credential writes", async () => {
  let put = false
  const denied: SecretStore = {
    async get() {
      throw new Error("store locked")
    },
    async put() {
      put = true
    },
    async remove() {},
  }
  await expect(new IdentityStore(denied, storage).loadOrCreate(["127.0.0.1"])).rejects.toThrow(
    "store locked",
  )
  expect(put).toBe(false)
  expect(readdirSync(storage.path)).toEqual(["catalog-id.json"])
})

test("invalid IPv4 input does not create identity", async () => {
  const store = new IdentityStore(secrets, storage)
  for (const input of [
    [],
    ["example.com"],
    ["::1"],
    ["127.0.0.1\nsubjectAltName=DNS:evil"],
    ["127.0.0.01"],
  ])
    await expect(store.loadOrCreate(input)).rejects.toMatchObject({ code: "invalidRequest" })
  expect(await secrets.get("tls-identity-v1")).toBeNull()
  expect(readdirSync(storage.path)).toEqual(["catalog-id.json"])
})

test("expired identity is rejected without replacement", async () => {
  const store = new IdentityStore(secrets, storage)
  await store.loadOrCreate(["127.0.0.1"])
  const original = await secrets.get("tls-identity-v1")
  const clock = spyOn(Date, "now").mockReturnValue(Date.UTC(2099, 0, 1))
  try {
    await expect(store.loadOrCreate(["127.0.0.1"])).rejects.toMatchObject({
      code: "corruptIdentity",
    })
    expect(await secrets.get("tls-identity-v1")).toEqual(original)
  } finally {
    clock.mockRestore()
  }
})

test("Bun TLS presents the saved certificate and enforces client hostname validation", async () => {
  const identity = await new IdentityStore(secrets, storage).loadOrCreate(["127.0.0.1"])
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    tls: { key: identity.key, cert: identity.cert },
    fetch: () => new Response("ok"),
  })
  async function handshake(servername?: string): Promise<string> {
    return new Promise((resolve) => {
      const socket = connect({
        host: "127.0.0.1",
        port: server.port,
        ca: identity.cert,
        servername,
        rejectUnauthorized: true,
      })
      socket.once("secureConnect", () => {
        resolve(socket.authorized ? "authorized" : "unauthorized")
        socket.destroy()
      })
      socket.once("error", (error: NodeJS.ErrnoException) => {
        resolve(error.code ?? "error")
        socket.destroy()
      })
    })
  }
  try {
    expect(await handshake()).toBe("authorized")
    expect(await handshake("not-covered.invalid")).toBe("ERR_TLS_CERT_ALTNAME_INVALID")
  } finally {
    server.stop(true)
  }
})

test("concurrent identity loads share one certificate", async () => {
  const store = new IdentityStore(secrets, storage)
  const [first, second] = await Promise.all([
    store.loadOrCreate(["127.0.0.1"]),
    store.loadOrCreate(["127.0.0.1"]),
  ])
  expect(first.der).toEqual(second.der)
})
