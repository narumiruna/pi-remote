import { createHash, createPrivateKey, X509Certificate } from "node:crypto"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { isIPv4 } from "node:net"
import { join } from "node:path"
import type { SecretStore } from "./secrets.ts"
import { Fault, type PrivateStorage } from "./storage.ts"

export interface TLSIdentity {
  key: string
  cert: string
  der: Buffer
  addresses: string[]
}
interface SavedIdentity {
  version: 1
  key: string
  cert: string
  der: string
  addresses: string[]
}
const account = "tls-identity-v1"

function addresses(input: unknown): string[] {
  if (
    !Array.isArray(input) ||
    input.length === 0 ||
    input.length > 64 ||
    input.some((value) => typeof value !== "string" || !isIPv4(value))
  )
    throw new Fault("invalidRequest")
  return [...new Set(input as string[])].sort()
}
function fingerprint(der: Buffer): string {
  return createHash("sha256").update(der).digest("hex")
}
function decode(data: Buffer): TLSIdentity {
  try {
    if (data.length > 64 * 1024) throw new Error()
    const saved = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(data),
    ) as SavedIdentity
    if (
      saved.version !== 1 ||
      typeof saved.key !== "string" ||
      typeof saved.cert !== "string" ||
      typeof saved.der !== "string"
    )
      throw new Error()
    const allowed = addresses(saved.addresses)
    if (
      allowed.length !== saved.addresses.length ||
      allowed.some((value, index) => value !== saved.addresses[index])
    )
      throw new Error()
    const certificate = new X509Certificate(saved.cert)
    const der = Buffer.from(saved.der, "base64")
    if (
      der.toString("base64") !== saved.der ||
      !certificate.raw.equals(der) ||
      !certificate.checkPrivateKey(createPrivateKey(saved.key)) ||
      !certificate.verify(certificate.publicKey)
    )
      throw new Error()
    const now = Date.now()
    if (Date.parse(certificate.validFrom) > now || Date.parse(certificate.validTo) <= now)
      throw new Error()
    if (allowed.some((value) => certificate.checkIP(value) !== value)) throw new Error()
    const sans = certificate.subjectAltName?.split(", ").sort()
    if (
      !sans ||
      sans.length !== allowed.length ||
      sans.some((value, index) => value !== allowed.map((ip) => `IP Address:${ip}`).sort()[index])
    )
      throw new Error()
    return { key: saved.key, cert: saved.cert, der, addresses: allowed }
  } catch {
    throw new Fault(
      "corruptIdentity",
      "The saved TLS identity is invalid or expired. Restore it from backup, or explicitly replace identity and pair devices again.",
    )
  }
}
async function readIdentityOutput(stream: ReadableStream<Uint8Array>): Promise<string> {
  const reader = stream.getReader(),
    parts: Buffer[] = []
  let size = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > 32 * 1024) throw new Fault("storageLimit")
      parts.push(Buffer.from(value))
    }
    return Buffer.concat(parts).toString("utf8")
  } finally {
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}

export class IdentityStore {
  private pending?: Promise<TLSIdentity>
  private generator?: ReturnType<typeof Bun.spawn>
  private closed = false
  constructor(
    private readonly secrets: SecretStore,
    private readonly storage: PrivateStorage,
    private readonly signal?: AbortSignal,
  ) {}

  private check(): void {
    if (this.closed || this.signal?.aborted) throw new Fault("cancelled")
  }

  async close(): Promise<void> {
    this.closed = true
    const child = this.generator
    if (!child) return
    try {
      child.kill("SIGKILL")
    } catch {
      /* Exit is checked below. */
    }
    await child.exited
  }

  async loadOrCreate(
    selectedAddresses: string[],
    initialAddresses = selectedAddresses,
  ): Promise<TLSIdentity> {
    const allowed = addresses(selectedAddresses)
    const initial = addresses(initialAddresses)
    this.pending ??= this.load(initial).finally(() => {
      this.pending = undefined
    })
    const identity = await this.pending
    if (allowed.some((value) => !identity.addresses.includes(value)))
      throw new Fault(
        "identityAddressMismatch",
        "The saved certificate does not cover this address. Select a covered address or explicitly replace identity and pair again.",
      )
    return identity
  }

  private async load(allowed: string[]): Promise<TLSIdentity> {
    this.check()
    const marker = await this.storage.readJSON<{ version: number; sha256: string }>(
      "identity.json",
      1024,
    )
    if (
      marker !== null &&
      (marker.version !== 1 ||
        typeof marker.sha256 !== "string" ||
        !/^[a-f0-9]{64}$/.test(marker.sha256))
    )
      throw new Fault("corruptIdentity")
    this.check()
    const saved = await this.secrets.get(account)
    this.check()
    let identity: TLSIdentity
    if (saved !== null) identity = decode(saved)
    else {
      if (marker !== null)
        throw new Fault(
          "missingIdentity",
          "The catalog TLS identity is missing from the OS secret store. Restore access to that store; identity is not replaced automatically.",
        )
      identity = await this.generate(allowed)
      const record: SavedIdentity = {
        version: 1,
        key: identity.key,
        cert: identity.cert,
        der: identity.der.toString("base64"),
        addresses: identity.addresses,
      }
      // Verify before writing either persistent record.
      decode(Buffer.from(JSON.stringify(record)))
      await this.secrets.put(account, Buffer.from(JSON.stringify(record)))
    }
    this.check()
    const sha256 = fingerprint(identity.der)
    if (marker !== null && marker.sha256 !== sha256)
      throw new Fault(
        "changedIdentity",
        "The OS secret-store identity does not match this catalog. Restore the original identity; no automatic replacement is permitted.",
      )
    if (marker === null) await this.storage.writeJSON("identity.json", { version: 1, sha256 }, 1024)
    return identity
  }

  private async generate(allowed: string[]): Promise<TLSIdentity> {
    // The parent is checked by PrivateStorage before this operation.
    this.check()
    await this.storage.readJSON("identity.json", 1024)
    this.check()
    const scratch = mkdtempSync(join(this.storage.path, "identity-scratch-"))
    try {
      const configPath = join(scratch, "openssl.cnf")
      // Darwin LibreSSL reopens stdout; Linux socket-backed stdio needs OpenSSL's dash target.
      const outputTarget = process.platform === "darwin" ? "/dev/stdout" : "-"
      writeFileSync(
        configPath,
        `[req]\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\n[ext]\nsubjectAltName=${allowed.map((ip) => `IP:${ip}`).join(",")}\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=serverAuth\n`,
        { flag: "wx", mode: 0o600 },
      )
      let child: ReturnType<typeof Bun.spawn>
      try {
        child = Bun.spawn(
          [
            "/usr/bin/openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-sha256",
            "-days",
            "365",
            "-subj",
            "/CN=Pi Remote Headless",
            "-config",
            configPath,
            "-keyout",
            outputTarget,
            "-out",
            outputTarget,
          ],
          { stdin: "ignore", stdout: "pipe", stderr: "ignore" },
        )
      } catch {
        throw new Fault(
          "opensslUnavailable",
          "TLS identity creation requires /usr/bin/openssl. Install OpenSSL, then retry.",
        )
      }
      this.generator = child
      const cancel = () => {
        try {
          child.kill("SIGKILL")
        } catch {
          /* Confirm exit below. */
        }
      }
      this.signal?.addEventListener("abort", cancel, { once: true })
      if (this.signal?.aborted) cancel()
      const deadline = setTimeout(cancel, 30_000)
      try {
        // Key material stays in a bounded private pipe, including during generation.
        const [status, output] = await Promise.all([
          child.exited,
          readIdentityOutput(child.stdout as ReadableStream<Uint8Array>),
        ])
        this.check()
        if (status !== 0)
          throw new Fault(
            "identityCreationFailed",
            "OpenSSL could not create a TLS identity. Check the private catalog and OpenSSL installation.",
          )
        const key = output.match(/-----BEGIN ((?:RSA )?PRIVATE KEY)-----[\s\S]*?-----END \1-----/)
        const cert = output.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/)
        if (!key || !cert) throw new Fault("identityCreationFailed")
        return {
          key: `${key[0]}\n`,
          cert: `${cert[0]}\n`,
          der: new X509Certificate(cert[0]).raw,
          addresses: allowed,
        }
      } finally {
        clearTimeout(deadline)
        this.signal?.removeEventListener("abort", cancel)
        if (child.exitCode === null) cancel()
        await child.exited
        if (this.generator === child) this.generator = undefined
      }
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }
}
