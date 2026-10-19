import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto"
import { networkInterfaces } from "node:os"
import type { Server, ServerWebSocket } from "bun"
import type { Coordinator } from "./coordinator.ts"
import { faultCode, foundationNow } from "./errors.ts"
import type { TLSIdentity } from "./identity.ts"
import { decodeClient, enumValue, type HostSnapshot, MAX_PACKET_BYTES, packet } from "./protocol.ts"
import type { SecretStore } from "./secrets.ts"
import { Fault, type PrivateStorage } from "./storage.ts"

export function allowedAddress(address: string): boolean {
  const parts = address.split(".")
  if (
    parts.length !== 4 ||
    parts.some((part) => !/^(0|[1-9][0-9]{0,2})$/.test(part) || Number(part) > 255)
  )
    return false
  const [a, b] = parts.map(Number)
  return (
    a === 127 ||
    a === 10 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 100 && b >= 64 && b <= 127)
  )
}
export function listenAddresses(): string[] {
  return [
    ...new Set(
      Object.values(networkInterfaces()).flatMap((entries) =>
        (entries ?? [])
          .filter((entry) => entry.family === "IPv4" && allowedAddress(entry.address))
          .map((entry) => entry.address),
      ),
    ),
  ].sort()
}
export function chooseAddress(address?: string): string {
  const all = listenAddresses()
  if (address) {
    if (!allowedAddress(address) || !all.includes(address))
      throw new Fault(
        "invalidRequest",
        "Choose an assigned private IPv4 address with pi-remote addresses.",
      )
    return address
  }
  const nonLoopback = all.filter((value) => !value.startsWith("127."))
  if (nonLoopback.length !== 1)
    throw new Fault("invalidRequest", "Choose --listen IPv4 after running pi-remote addresses.")
  return nonLoopback[0]
}

type Device = { id: string; name: string }
type Peer = {
  id: string
  nonce: Buffer
  phase: "challenge" | "pending" | "authenticated"
  device?: string
  deadline: number
  authorized: boolean
  inFlight: Set<string>
  busy: boolean
}
export type PendingPair = { id: string; device: Device }

/** No remote path reaches the coordinator before authentication. */
export class AppServer {
  private listener?: Server<Peer>
  private peers = new Map<string, ServerWebSocket<Peer>>()
  private devices: Device[] = []
  private grant?: { bytes: Buffer; expires: number; attempts: number }
  private pending?: PendingPair
  private approving = false
  private observers = new Set<(pending?: PendingPair) => void>()
  private unsubscribe?: () => void
  private timer?: ReturnType<typeof setInterval>
  private stopped = false
  private constructor(
    readonly coordinator: Coordinator,
    private storage: PrivateStorage,
    private secrets: SecretStore,
  ) {}

  static async start(options: {
    coordinator: Coordinator
    storage: PrivateStorage
    secrets: SecretStore
    identity: TLSIdentity
    address: string
    port: number
  }): Promise<AppServer> {
    if (
      !allowedAddress(options.address) ||
      !listenAddresses().includes(options.address) ||
      !options.identity.addresses.includes(options.address)
    )
      throw new Fault("invalidRequest")
    const server = new AppServer(options.coordinator, options.storage, options.secrets)
    const metadata = await options.storage.readJSON("devices.json")
    if (metadata !== null) {
      if (!Array.isArray(metadata) || metadata.length > 16) throw new Fault("storageFailure")
      const ids = new Set<string>()
      server.devices = metadata.map((value: unknown) => {
        if (!value || typeof value !== "object") throw new Fault("storageFailure")
        const item = value as Device
        if (
          !/^[0-9A-F-]{36}$/.test(item.id) ||
          ids.has(item.id) ||
          typeof item.name !== "string" ||
          Buffer.byteLength(item.name) > 128
        )
          throw new Fault("storageFailure")
        ids.add(item.id)
        return { id: item.id, name: item.name }
      })
    }
    server.listener = Bun.serve<Peer>({
      hostname: options.address,
      port: options.port,
      tls: { key: options.identity.key, cert: options.identity.cert },
      maxRequestBodySize: MAX_PACKET_BYTES,
      idleTimeout: 10,
      fetch(request, instance) {
        if (
          server.stopped ||
          server.peers.size >= 16 ||
          request.method !== "GET" ||
          new URL(request.url).pathname !== "/"
        )
          return new Response(null, { status: 403 })
        const data: Peer = {
          id: randomUUID().toUpperCase(),
          nonce: randomBytes(32),
          phase: "challenge",
          deadline: performance.now() + 10_000,
          authorized: true,
          inFlight: new Set(),
          busy: false,
        }
        if (instance.upgrade(request, { data })) return undefined
        return new Response(null, { status: 400 })
      },
      websocket: {
        maxPayloadLength: MAX_PACKET_BYTES,
        backpressureLimit: 8 * 1024 * 1024,
        closeOnBackpressureLimit: true,
        idleTimeout: 65,
        sendPings: false,
        open(socket) {
          if (server.peers.size >= 16 || server.stopped) {
            socket.close()
            return
          }
          server.peers.set(socket.data.id, socket)
          server.send(socket, { challenge: { nonce: socket.data.nonce.toString("base64") } })
        },
        message(socket, message) {
          void server.receive(socket, message).catch(() => server.remove(socket))
        },
        close(socket) {
          server.remove(socket)
        },
      },
      error() {
        return new Response(null, { status: 500 })
      },
    })
    server.unsubscribe = options.coordinator.subscribe((state) => server.broadcast(state))
    server.timer = setInterval(() => server.sweep(), 1000)
    server.timer.unref()
    return server
  }
  get port(): number {
    return this.listener?.port ?? 0
  }
  get running(): boolean {
    return !this.stopped && !!this.listener
  }
  get pendingPair(): PendingPair | undefined {
    return this.pending
  }
  listDevices(): (Device & { connected: boolean })[] {
    return this.devices.map((device) => ({
      ...device,
      connected: [...this.peers.values()].some(
        (socket) => socket.data.authorized && socket.data.device === device.id,
      ),
    }))
  }
  observePairing(observer: (pending?: PendingPair) => void): () => void {
    this.observers.add(observer)
    return () => this.observers.delete(observer)
  }
  private publishPending(value?: PendingPair): void {
    this.pending = value
    for (const listener of this.observers) listener(value)
  }
  openPairing(): Buffer {
    if (!this.running) throw new Fault("unavailable")
    this.closePairing()
    this.grant = { bytes: randomBytes(32), expires: performance.now() + 120_000, attempts: 0 }
    return this.grant.bytes
  }
  closePairing(): void {
    this.grant = undefined
    const peer = this.pending && this.peers.get(this.pending.id)
    if (peer) this.remove(peer)
    this.publishPending()
  }
  async approve(id: string): Promise<void> {
    if (this.approving) throw new Fault("conflict")
    this.approving = true
    try {
      const pending = this.pending,
        socket = this.peers.get(id)
      if (
        !pending ||
        pending.id !== id ||
        !socket ||
        socket.data.phase !== "pending" ||
        socket.data.deadline <= performance.now()
      )
        throw new Fault("expired")
      const credential = randomBytes(32)
      await this.secrets.put(pending.device.id, credential)
      if (
        this.stopped ||
        this.pending !== pending ||
        !socket.data.authorized ||
        socket.data.deadline <= performance.now()
      ) {
        await this.secrets.remove(pending.device.id)
        throw new Fault("expired")
      }
      const updated = [...this.devices, pending.device]
      try {
        await this.storage.writeJSON("devices.json", updated)
      } catch (error) {
        await this.secrets.remove(pending.device.id)
        throw error
      }
      this.devices = updated
      this.grant = undefined
      this.publishPending()
      this.send(socket, {
        paired: { credential: credential.toString("base64"), host: this.coordinator.snapshot.host },
      })
      socket.close(1000)
    } finally {
      this.approving = false
    }
  }
  deny(id: string): void {
    if (!this.pending || this.pending.id !== id) throw new Fault("expired")
    const socket = this.peers.get(id)
    this.grant = undefined
    this.publishPending()
    if (socket) {
      this.send(socket, enumValue("denied"))
      socket.close(1000)
    }
  }
  async revoke(id: string): Promise<void> {
    if (!this.devices.some((device) => device.id === id)) throw new Fault("invalidRequest")
    for (const socket of this.peers.values()) if (socket.data.device === id) this.remove(socket)
    this.devices = this.devices.filter((device) => device.id !== id)
    let failed = false
    try {
      await this.storage.writeJSON("devices.json", this.devices)
    } catch {
      failed = true
    }
    try {
      await this.secrets.remove(id)
    } catch {
      failed = true
    }
    if (failed) {
      await this.stop()
      throw new Fault("storageFailure")
    }
  }

  private async receive(socket: ServerWebSocket<Peer>, message: string | Buffer): Promise<void> {
    const peer = socket.data
    if (!peer.authorized || peer.deadline < performance.now() || this.stopped) {
      this.remove(socket)
      return
    }
    const incoming = decodeClient(message)
    if (peer.phase === "challenge" && !peer.busy) {
      peer.busy = true
      peer.phase = "pending"
      if (incoming.kind === "pair") {
        const grant = this.grant
        if (grant) grant.attempts += 1
        if (
          !grant ||
          grant.attempts > 5 ||
          grant.expires <= performance.now() ||
          !timingSafeEqual(grant.bytes, incoming.grant) ||
          this.pending ||
          this.devices.length >= 16 ||
          !incoming.name ||
          Buffer.byteLength(incoming.name) > 128 ||
          this.devices.some((device) => device.id === incoming.device)
        ) {
          this.reject(socket)
          return
        }
        peer.deadline = grant.expires
        this.grant = undefined
        this.publishPending({ id: peer.id, device: { id: incoming.device, name: incoming.name } })
        this.send(socket, enumValue("approvalRequired"))
        return
      }
      if (incoming.kind === "authenticate") {
        const device = this.devices.find((value) => value.id === incoming.device)
        const secret = device ? await this.secrets.get(device.id) : null
        const input = Buffer.concat([
          Buffer.from(`PiRemote app protocol v1\0${incoming.device}\0`),
          peer.nonce,
        ])
        if (
          secret?.length !== 32 ||
          !timingSafeEqual(createHmac("sha256", secret).update(input).digest(), incoming.proof) ||
          !peer.authorized ||
          this.stopped ||
          !this.devices.some((value) => value.id === device?.id)
        ) {
          this.reject(socket)
          return
        }
        peer.phase = "authenticated"
        peer.device = incoming.device
        peer.deadline = performance.now() + 60_000
        this.send(socket, {
          authenticated: {
            host: this.coordinator.snapshot.host,
            epoch: this.coordinator.snapshot.epoch,
          },
        })
        return
      }
      this.remove(socket)
      return
    }
    if (peer.phase !== "authenticated" || incoming.kind !== "request" || !peer.device) {
      this.remove(socket)
      return
    }
    if (peer.inFlight.size >= 8 || peer.inFlight.has(incoming.id)) {
      this.send(socket, { reply: { id: incoming.id, result: enumValue("failure", "capacity") } })
      return
    }
    peer.deadline = performance.now() + 60_000
    peer.inFlight.add(incoming.id)
    try {
      const result = await this.coordinator.handle(
        incoming,
        peer.device,
        () =>
          peer.authorized &&
          !this.stopped &&
          this.devices.some((device) => device.id === peer.device),
      )
      if (peer.authorized)
        this.send(socket, {
          reply: {
            id: incoming.id,
            result,
            ...(!["snapshot", "synchronize", "directories", "directoryAtPath"].includes(
              incoming.action,
            )
              ? { state: this.coordinator.wireSnapshot() }
              : {}),
          },
        })
    } catch (error) {
      this.send(socket, {
        reply: { id: incoming.id, result: enumValue("failure", faultCode(error)) },
      })
    } finally {
      peer.inFlight.delete(incoming.id)
    }
  }
  private send(socket: ServerWebSocket<Peer>, payload: Record<string, unknown>): void {
    if (!socket.data.authorized) return
    try {
      const sent = socket.send(packet(payload))
      // -1 means accepted into the bounded send buffer, not a failed send.
      if (sent === 0 || socket.getBufferedAmount() > 8 * 1024 * 1024) this.remove(socket)
    } catch {
      this.remove(socket)
    }
  }
  private broadcast(state: HostSnapshot): void {
    for (const socket of this.peers.values())
      if (socket.data.phase === "authenticated") this.send(socket, enumValue("state", state))
  }
  private reject(socket: ServerWebSocket<Peer>): void {
    this.send(socket, enumValue("denied"))
    socket.data.authorized = false
    this.peers.delete(socket.data.id)
    if (this.pending?.id === socket.data.id) this.publishPending()
    socket.close(1008)
  }
  private remove(socket: ServerWebSocket<Peer>): void {
    socket.data.authorized = false
    this.peers.delete(socket.data.id)
    if (this.pending?.id === socket.data.id) this.publishPending()
    socket.terminate()
  }
  private sweep(): void {
    const now = performance.now()
    if (this.grant && this.grant.expires <= now) this.grant = undefined
    for (const socket of this.peers.values()) if (socket.data.deadline <= now) this.remove(socket)
  }
  pairingCode(identity: TLSIdentity, address: string, name: string): string {
    const grant = this.openPairing()
    return Buffer.from(
      JSON.stringify({
        version: 1,
        host: this.coordinator.snapshot.host,
        name,
        url: `wss://${address}:${this.port}/`,
        certificate: identity.der.toString("base64"),
        grant: grant.toString("base64"),
        expires: foundationNow() + 120,
      }),
    ).toString("base64")
  }
  async stop(): Promise<void> {
    if (this.stopped) return
    this.stopped = true
    this.closePairing()
    this.unsubscribe?.()
    if (this.timer) clearInterval(this.timer)
    for (const peer of this.peers.values()) this.remove(peer)
    await this.listener?.stop(true)
    this.listener = undefined
  }
}
