import { fileURLToPath } from "node:url"
import { Fault } from "./storage.ts"

export interface SecretStore {
  get(account: string): Promise<Buffer | null>
  put(account: string, data: Buffer): Promise<void>
  remove(account: string): Promise<void>
  close?(): Promise<void>
}

/** OS calls run behind bounded private pipes so a locked store cannot block host cleanup. */
export class OSSecrets implements SecretStore {
  readonly service: string
  private closed = false
  private workers = new Set<() => void>()
  private tasks = new Set<Promise<Buffer | null>>()
  private workerEntry = fileURLToPath(
    new URL(
      import.meta.url.endsWith(".ts") ? "./secret-worker.ts" : "./host/secret-worker.js",
      import.meta.url,
    ),
  )
  private readonly abort = () => {
    void this.close()
  }

  constructor(
    catalogID: string,
    private signal?: AbortSignal,
  ) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(catalogID))
      throw new Fault("invalidRequest")
    this.service = `app.pi-remote.headless.${catalogID.toLowerCase()}`
    if (signal?.aborted) this.closed = true
    else signal?.addEventListener("abort", this.abort, { once: true })
  }

  private unavailable(): Fault {
    return new Fault(
      "secretStoreUnavailable",
      process.platform === "linux"
        ? "Cannot access Linux Secret Service. Start and unlock a Secret Service provider in this user's D-Bus session, then retry. No plaintext or kernel-keyring fallback is used."
        : "Cannot access macOS Keychain. Unlock the login Keychain and allow this host to access its own credentials, then retry.",
    )
  }

  private operation(
    operation: "get" | "put" | "remove",
    account: string,
    data?: Buffer,
  ): Promise<Buffer | null> {
    if (!account || Buffer.byteLength(account) > 256 || account.includes("\0"))
      return Promise.reject(new Fault("invalidRequest"))
    if (process.platform !== "darwin" && process.platform !== "linux")
      return Promise.reject(new Fault("unsupportedFeature"))
    if (this.closed) return Promise.reject(this.unavailable())
    if (this.tasks.size >= 8) return Promise.reject(new Fault("capacity"))
    const task = this.execute({
      operation,
      account,
      service: this.service,
      data: data?.toString("base64"),
    })
    this.tasks.add(task)
    void task.then(
      () => this.tasks.delete(task),
      () => this.tasks.delete(task),
    )
    return task
  }

  private async execute(input: Record<string, unknown>): Promise<Buffer | null> {
    const child = Bun.spawn([process.execPath, this.workerEntry], {
      stdin: Buffer.from(JSON.stringify(input)),
      stdout: "pipe",
      stderr: "ignore",
    })
    const reader = child.stdout.getReader()
    let cancelled = false
    const cancel = () => {
      cancelled = true
      try {
        child.kill("SIGKILL")
      } catch {
        /* Exit can race cancellation. */
      }
      void reader.cancel().catch(() => {})
    }
    this.workers.add(cancel)
    const timer = setTimeout(cancel, 5000)
    try {
      let bytes = Buffer.alloc(0)
      for (;;) {
        const chunk = await reader.read()
        if (chunk.done) break
        if (bytes.length + chunk.value.length > 1_400_000) {
          cancel()
          throw this.unavailable()
        }
        bytes = Buffer.concat([bytes, chunk.value])
      }
      if ((await child.exited) !== 0 || cancelled || this.closed) throw this.unavailable()
      const result = JSON.parse(bytes.toString("utf8")) as { ok: boolean; data?: string | null }
      if (result.ok !== true || (result.data !== null && typeof result.data !== "string"))
        throw this.unavailable()
      if (result.data === null) return null
      const data = Buffer.from(result.data ?? "", "base64")
      if (data.length > 1024 * 1024 || data.toString("base64") !== result.data)
        throw this.unavailable()
      return data
    } catch {
      throw this.unavailable()
    } finally {
      clearTimeout(timer)
      this.workers.delete(cancel)
      if (child.exitCode === null) {
        try {
          child.kill("SIGKILL")
        } catch {
          /* Already exited. */
        }
      }
      await reader.cancel().catch(() => {})
      await child.exited
    }
  }

  get(account: string): Promise<Buffer | null> {
    return this.operation("get", account)
  }
  async put(account: string, data: Buffer): Promise<void> {
    if (!Buffer.isBuffer(data) || data.length > 1024 * 1024) throw new Fault("secretLimit")
    await this.operation("put", account, data)
  }
  async remove(account: string): Promise<void> {
    await this.operation("remove", account)
  }
  async close(): Promise<void> {
    this.closed = true
    this.signal?.removeEventListener("abort", this.abort)
    for (const cancel of this.workers) cancel()
    await Promise.allSettled([...this.tasks])
  }
}
