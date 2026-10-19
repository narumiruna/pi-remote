import { createHmac, randomUUID, X509Certificate } from "node:crypto"
import { isIP } from "node:net"
import { checkServerIdentity } from "node:tls"
import type { TLSIdentity } from "../host/identity.ts"
import { enumValue, type HostSnapshot, packet } from "../host/protocol.ts"
import type { SecretStore } from "../host/secrets.ts"

export function required<T>(value: T | undefined | null): T {
  if (value === undefined || value === null) throw new Error("Required fixture value is missing")
  return value
}

/** Tests use memory credentials, never the user's OS secret store. */
export class MemorySecrets implements SecretStore {
  readonly values = new Map<string, Buffer>()
  failRemove = false
  async get(account: string): Promise<Buffer | null> {
    return this.values.get(account) ?? null
  }
  async put(account: string, data: Buffer): Promise<void> {
    this.values.set(account, Buffer.from(data))
  }
  async remove(account: string): Promise<void> {
    if (this.failRemove) throw new Error("fixture secret removal failed")
    this.values.delete(account)
  }
}

export interface Payload {
  nonce?: string
  credential?: string
  host?: string
  epoch?: string
  id?: string
  result?: Record<string, unknown>
  state?: HostSnapshot
  _0?: HostSnapshot
}

/** A real WSS peer with a trusted test certificate and hostname checks enabled. */
export class TestClient {
  readonly socket: WebSocket
  readonly closed: Promise<void>
  private messages: { kind: string; value: Payload }[] = []
  private wake?: () => void
  private ended = false

  constructor(port: number, identity: TLSIdentity, hostname = "127.0.0.1") {
    // Bun WebSocket currently ignores checkServerIdentity. Check the exact trusted
    // certificate before connecting; CA verification remains enabled on the socket.
    const certificate = new X509Certificate(identity.cert)
    if (!(isIP(hostname) ? certificate.checkIP(hostname) : certificate.checkHost(hostname)))
      throw new Error("Pinned certificate hostname mismatch")
    if (
      Date.parse(certificate.validFrom) > Date.now() ||
      Date.parse(certificate.validTo) <= Date.now()
    )
      throw new Error("Pinned certificate expired or not yet valid")
    const ClientWebSocket = WebSocket as unknown as new (
      url: string,
      options: { tls: Bun.TLSOptions & { checkServerIdentity: typeof checkServerIdentity } },
    ) => WebSocket
    this.socket = new ClientWebSocket(`wss://127.0.0.1:${port}/`, {
      tls: {
        ca: identity.cert,
        serverName: hostname,
        checkServerIdentity: (_host, cert) => checkServerIdentity(hostname, cert),
      },
    })
    this.socket.addEventListener("message", (event) => {
      const frame = JSON.parse(String(event.data)) as {
        version: number
        payload: Record<string, Payload>
      }
      if (frame.version !== 1) throw new Error("Unexpected protocol version")
      for (const [kind, value] of Object.entries(frame.payload)) this.messages.push({ kind, value })
      this.wake?.()
    })
    this.closed = new Promise((resolve) => {
      this.socket.addEventListener("close", () => {
        this.ended = true
        this.wake?.()
        resolve()
      })
      this.socket.addEventListener("error", () => {
        this.ended = true
        this.wake?.()
        resolve()
      })
    })
  }

  send(payload: Record<string, unknown>): void {
    this.socket.send(packet(payload))
  }
  close(): void {
    this.socket.close()
  }
  async wait(kind: string, timeout = 3000): Promise<Payload> {
    const deadline = performance.now() + timeout
    for (;;) {
      const index = this.messages.findIndex((entry) => entry.kind === kind)
      if (index >= 0) return required(this.messages.splice(index, 1)[0]).value
      if (this.ended) throw new Error(`Connection ended before ${kind}`)
      const remaining = deadline - performance.now()
      if (remaining <= 0) throw new Error(`Timed out waiting for ${kind}`)
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, remaining)
        this.wake = () => {
          clearTimeout(timer)
          resolve()
        }
      })
      this.wake = undefined
    }
  }
  async authenticate(
    device: string,
    credential: Buffer,
    canonical = device.toUpperCase(),
    nonce?: string,
  ): Promise<void> {
    const challenge = nonce ?? required((await this.wait("challenge")).nonce)
    const input = Buffer.concat([
      Buffer.from(`PiRemote app protocol v1\0${canonical}\0`),
      Buffer.from(challenge, "base64"),
    ])
    const proof = createHmac("sha256", credential).update(input).digest("base64")
    this.send({ authenticate: { device, proof } })
  }
  request(
    epoch: string,
    action: string,
    fields: Record<string, unknown> = {},
    session?: string,
    id = randomUUID().toUpperCase(),
  ): string {
    this.send(
      enumValue("request", {
        id,
        epoch,
        ...(session ? { session } : {}),
        action: { [action]: fields },
      }),
    )
    return id
  }
}

export async function until(check: () => boolean, timeout = 3000): Promise<void> {
  const deadline = performance.now() + timeout
  while (!check()) {
    if (performance.now() >= deadline) throw new Error("Condition did not become true")
    await Bun.sleep(5)
  }
}
