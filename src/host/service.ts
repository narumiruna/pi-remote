import { realpath, stat } from "node:fs/promises"
import { homedir } from "node:os"
import { delimiter, resolve } from "node:path"
import { Coordinator } from "./coordinator.ts"
import { DirectoryAccess } from "./directories.ts"
import { displayText } from "./errors.ts"
import { IdentityStore, type TLSIdentity } from "./identity.ts"
import { OSSecrets, type SecretStore } from "./secrets.ts"
import { AppServer, chooseAddress, listenAddresses } from "./server.ts"
import { Fault, PrivateStorage } from "./storage.ts"

export interface ServiceOptions {
  directory: string
  dataDirectory: string
  address?: string
  port: number
  pi?: string
}
export function defaultDataDirectory(): string {
  return process.platform === "darwin"
    ? resolve(homedir(), "Library/Application Support/PiRemoteCLI")
    : resolve(homedir(), ".local/share/pi-remote")
}
export async function piEntry(path?: string): Promise<string> {
  const selected =
    path ??
    (process.env.PATH ?? "")
      .split(delimiter)
      .filter(Boolean)
      .map((directory) => resolve(directory, "pi"))
      .find((candidate) => Bun.file(candidate).size > 0)
  if (!selected)
    throw new Fault(
      "piLaunchFailed",
      "Install and configure Pi, or select its JavaScript entry with --pi PATH.",
    )
  const canonical = await realpath(selected).catch(() => {
    throw new Fault("piLaunchFailed", "Pi entry was not found. Check --pi PATH.")
  })
  const info = await stat(canonical)
  if (!info.isFile() || info.size > 128 * 1024 * 1024) throw new Fault("piLaunchFailed")
  const prefix = await Bun.file(canonical).slice(0, 256).text()
  if (prefix.startsWith("#!/bin/sh") || prefix.startsWith("#!/bin/bash") || prefix.includes("\0"))
    throw new Fault(
      "piLaunchFailed",
      "--pi must select Pi's JavaScript entry so Bun can execute it directly.",
    )
  return canonical
}

async function inspectVersion(entry: string, cwd: string, signal?: AbortSignal): Promise<string> {
  signal?.throwIfAborted()
  const child = Bun.spawn([process.execPath, entry, "--version"], {
    cwd,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  })
  const reader = child.stdout.getReader()
  const abort = () => {
    child.kill("SIGKILL")
    void reader.cancel().catch(() => {})
  }
  signal?.addEventListener("abort", abort, { once: true })
  const timer = setTimeout(abort, 5000)
  try {
    let data = Buffer.alloc(0)
    for (;;) {
      const chunk = await reader.read()
      if (chunk.done) break
      data = Buffer.concat([data, chunk.value])
      if (data.length > 256) {
        child.kill("SIGKILL")
        throw new Fault("piLaunchFailed")
      }
    }
    if ((await child.exited) !== 0)
      throw new Fault(
        "piLaunchFailed",
        "Pi's Bun startup check failed. Check --pi and the installed Pi version.",
      )
    const version = displayText(data.toString("utf8").trim(), 128)
    if (!version) throw new Fault("piLaunchFailed")
    signal?.throwIfAborted()
    return version
  } finally {
    clearTimeout(timer)
    signal?.removeEventListener("abort", abort)
    if (child.exitCode === null) child.kill("SIGKILL")
    await reader.cancel().catch(() => {})
    await child.exited
  }
}

async function abortable<T>(operation: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return operation
  return new Promise<T>((resolve, reject) => {
    const abort = () => reject(new Fault("cancelled"))
    signal.addEventListener("abort", abort, { once: true })
    if (signal.aborted) abort()
    void operation.then(
      (value) => {
        signal.removeEventListener("abort", abort)
        resolve(value)
      },
      (error) => {
        signal.removeEventListener("abort", abort)
        reject(error)
      },
    )
  })
}

export class Service {
  private stopping?: Promise<void>
  private constructor(
    readonly coordinator: Coordinator,
    readonly server: AppServer,
    readonly identity: TLSIdentity,
    readonly address: string,
    private secrets: SecretStore,
  ) {}
  static async start(
    options: ServiceOptions,
    injection: {
      secrets?: SecretStore
      piArgs?: string[]
      env?: Record<string, string>
      signal?: AbortSignal
    } = {},
  ): Promise<Service> {
    injection.signal?.throwIfAborted()
    const address = chooseAddress(options.address)
    const entry = await piEntry(options.pi)
    const directories = new DirectoryAccess(options.directory)
    let storage: PrivateStorage | undefined,
      coordinator: Coordinator | undefined,
      server: AppServer | undefined,
      secrets: SecretStore | undefined,
      identityStore: IdentityStore | undefined
    try {
      await directories.list()
      storage = await PrivateStorage.initialize(options.dataDirectory)
      const version = await inspectVersion(entry, options.directory, injection.signal)
      secrets = injection.secrets ?? new OSSecrets(storage.catalogID, injection.signal)
      identityStore = new IdentityStore(secrets, storage, injection.signal)
      const identity = await abortable(
        identityStore.loadOrCreate([address], listenAddresses()),
        injection.signal,
      )
      injection.signal?.throwIfAborted()
      coordinator = await Coordinator.open({
        storage,
        directories,
        entry,
        piArgs: injection.piArgs,
        env: injection.env,
      })
      coordinator.setVersion(version)
      server = await AppServer.start({
        coordinator,
        storage,
        secrets,
        identity,
        address,
        port: options.port,
      })
      injection.signal?.throwIfAborted()
      return new Service(coordinator, server, identity, address, secrets)
    } catch (error) {
      await server?.stop()
      try {
        await Promise.all([secrets?.close?.(), identityStore?.close()])
      } finally {
        if (coordinator) await coordinator.shutdown()
        else {
          directories.close()
          storage?.close()
        }
      }
      throw error
    }
  }
  stop(): Promise<void> {
    this.stopping ??= (async () => {
      await this.server.stop()
      await Promise.all([this.secrets.close?.(), this.coordinator.shutdown()])
    })()
    return this.stopping
  }
}
