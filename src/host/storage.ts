import { dlopen, ptr } from "bun:ffi"
import { randomUUID } from "node:crypto"
import {
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  realpathSync,
  writeSync,
} from "node:fs"
import { basename, dirname, join, resolve } from "node:path"

export class Fault extends Error {
  constructor(
    public readonly code: string,
    message = code,
  ) {
    super(message)
    this.name = "Fault"
  }
}

const mac = process.platform === "darwin"
const supported = mac || process.platform === "linux"
const closeOnExec = mac ? 0x1000000 : 0x80000
const atCWD = mac ? -2 : -100
let native: ReturnType<typeof openNative> | undefined
function openNative() {
  if (!supported) throw new Fault("unsupportedFeature", "Private storage requires macOS or Linux.")
  try {
    return dlopen(mac ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
      openat: { args: ["i32", "ptr", "i32", "u32"], returns: "i32" },
      renameat: { args: ["i32", "ptr", "i32", "ptr"], returns: "i32" },
      unlinkat: { args: ["i32", "ptr", "i32"], returns: "i32" },
      flock: { args: ["i32", "i32"], returns: "i32" },
    })
  } catch {
    throw new Fault(
      "unsupportedFeature",
      "Private storage requires the macOS system library or Linux glibc (libc.so.6) with flock support.",
    )
  }
}
function libc() {
  native ??= openNative()
  return native.symbols
}
function cstring(value: string) {
  return Buffer.from(`${value}\0`)
}
function openAt(fd: number, name: string, flags: number): number {
  const bytes = cstring(name)
  // Existing files only: the variadic mode argument is never read by libc.
  return libc().openat(fd, ptr(bytes), flags | closeOnExec | constants.O_NOFOLLOW, 0)
}
function validName(name: string) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(name)) throw new Fault("invalidRequest")
}
function privateFile(fd: number) {
  const stat = fstatSync(fd, { bigint: true })
  if (
    !stat.isFile() ||
    stat.nlink !== 1n ||
    stat.uid !== BigInt(process.getuid?.() ?? -1) ||
    (stat.mode & 0o7777n) !== 0o600n
  ) {
    throw new Fault(
      "unsafeStorage",
      "Storage files must be owned, private regular files with one link.",
    )
  }
  return stat
}

/** Metadata only. Credentials and TLS private keys belong in SecretStore. */
export class PrivateStorage {
  readonly catalogID: string
  private closed = false

  private constructor(
    public readonly path: string,
    private readonly fd: number,
    private readonly inode: string,
  ) {
    const saved = this.readJSONSync("catalog-id.json", 1024)
    if (saved === null) {
      this.catalogID = randomUUID()
      this.writeJSONSync("catalog-id.json", { version: 1, id: this.catalogID }, 1024)
    } else {
      const record = saved as { version?: unknown; id?: unknown }
      if (
        record?.version !== 1 ||
        typeof record.id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(record.id)
      ) {
        throw new Fault(
          "corruptStorage",
          "The catalog identity is invalid; restore the catalog backup.",
        )
      }
      this.catalogID = record.id
    }
  }

  /** Takes the kernel lease before reading or creating any catalog metadata. */
  static async initialize(path: string): Promise<PrivateStorage> {
    if (!path || path.includes("\0")) throw new Fault("invalidRequest")
    const absolute = resolve(path)
    mkdirSync(absolute, { recursive: true, mode: 0o700 })
    // Resolve parent aliases (for example /tmp on macOS), but never the catalog itself.
    const canonical = join(realpathSync(dirname(absolute)), basename(absolute))
    const before = lstatSync(canonical, { bigint: true })
    if (before.isSymbolicLink()) throw new Fault("unsafeStorage")
    const fd = openAt(
      atCWD,
      canonical,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NONBLOCK,
    )
    if (fd < 0) throw new Fault("unsafeStorage", "Cannot open the private catalog directory.")
    try {
      const info = fstatSync(fd, { bigint: true })
      if (
        !info.isDirectory() ||
        info.uid !== BigInt(process.getuid?.() ?? -1) ||
        (info.mode & 0o7777n) !== 0o700n ||
        info.dev !== before.dev ||
        info.ino !== before.ino
      ) {
        throw new Fault(
          "unsafeStorage",
          "The catalog must be an owned directory with mode 0700. Existing permissions are not changed.",
        )
      }
      // LOCK_EX | LOCK_NB. The kernel releases this lease when the process dies.
      if (libc().flock(fd, 2 | 4) !== 0)
        throw new Fault(
          "catalogBusy",
          "Another host owns this catalog, or the filesystem does not support flock.",
        )
      return new PrivateStorage(canonical, fd, `${info.dev}:${info.ino}`)
    } catch (error) {
      closeSync(fd)
      throw error
    }
  }

  private check() {
    if (this.closed) throw new Fault("storageClosed")
    const info = lstatSync(this.path, { bigint: true })
    if (
      !info.isDirectory() ||
      `${info.dev}:${info.ino}` !== this.inode ||
      info.uid !== BigInt(process.getuid?.() ?? -1) ||
      (info.mode & 0o7777n) !== 0o700n
    )
      throw new Fault("unsafeStorage")
  }

  private readJSONSync(name: string, maxBytes: number): unknown | null {
    this.check()
    validName(name)
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > 16 * 1024 * 1024)
      throw new Fault("invalidRequest")
    const fd = openAt(this.fd, name, constants.O_RDONLY | constants.O_NONBLOCK)
    if (fd < 0) {
      // Distinguish absence from links, denial, and special files without following them.
      try {
        lstatSync(join(this.path, name))
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return null
      }
      throw new Fault("unsafeStorage")
    }
    try {
      const info = privateFile(fd)
      if (info.size > BigInt(maxBytes)) throw new Fault("storageLimit")
      const bytes = Buffer.alloc(maxBytes + 1)
      let total = 0
      while (total <= maxBytes) {
        const count = readSync(fd, bytes, total, bytes.length - total, null)
        if (count === 0) break
        total += count
      }
      if (total > maxBytes) throw new Fault("storageLimit")
      privateFile(fd)
      try {
        const value: unknown = JSON.parse(
          new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, total)),
        )
        // null is reserved for an absent file, not a valid metadata record.
        if (value === null) throw new Fault("corruptStorage")
        return value
      } catch {
        throw new Fault("corruptStorage")
      }
    } finally {
      closeSync(fd)
    }
  }

  async readJSON<T = unknown>(name: string, maxBytes = 1024 * 1024): Promise<T | null> {
    return this.readJSONSync(name, maxBytes) as T | null
  }

  private writeJSONSync(name: string, value: unknown, maxBytes: number) {
    this.check()
    validName(name)
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > 16 * 1024 * 1024)
      throw new Fault("invalidRequest")
    let encoded: string | undefined
    try {
      encoded = JSON.stringify(value)
    } catch {
      throw new Fault("invalidRequest")
    }
    if (encoded === undefined || encoded === "null") throw new Fault("invalidRequest")
    const bytes = Buffer.from(encoded)
    if (bytes.length > maxBytes) throw new Fault("storageLimit")
    // Validate an existing destination. Never chmod or follow another file.
    const existing = openAt(this.fd, name, constants.O_RDONLY | constants.O_NONBLOCK)
    if (existing >= 0) {
      try {
        privateFile(existing)
      } finally {
        closeSync(existing)
      }
    } else {
      try {
        lstatSync(join(this.path, name))
        throw new Fault("unsafeStorage")
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error
      }
    }
    const temporary = `atomic-${randomUUID()}.tmp`
    // Node handles the platform-specific variadic open ABI (macOS arm64).
    // O_EXCL creates only a new file. Verify it through the anchored directory
    // before writing, so a replaced parent cannot redirect catalog data.
    const fd = openSync(
      join(this.path, temporary),
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    )
    try {
      this.check()
      const created = privateFile(fd)
      const anchored = openAt(this.fd, temporary, constants.O_RDONLY | constants.O_NONBLOCK)
      if (anchored < 0) throw new Fault("unsafeStorage")
      try {
        const actual = privateFile(anchored)
        if (actual.dev !== created.dev || actual.ino !== created.ino)
          throw new Fault("unsafeStorage")
      } finally {
        closeSync(anchored)
      }
      let offset = 0
      while (offset < bytes.length) {
        const count = writeSync(fd, bytes, offset, bytes.length - offset)
        if (count <= 0) throw new Fault("storageWriteFailed")
        offset += count
      }
      fsyncSync(fd)
      this.check()
      const source = cstring(temporary)
      const destination = cstring(name)
      if (libc().renameat(this.fd, ptr(source), this.fd, ptr(destination)) !== 0)
        throw new Fault("storageWriteFailed")
      fsyncSync(this.fd)
    } finally {
      closeSync(fd)
      const source = cstring(temporary)
      libc().unlinkat(this.fd, ptr(source), 0)
    }
  }

  async writeJSON(name: string, value: unknown, maxBytes = 1024 * 1024): Promise<void> {
    this.writeJSONSync(name, value, maxBytes)
  }

  close(): void {
    if (!this.closed) {
      this.closed = true
      // Do not explicitly unlock: close releases the descriptor and its lease together.
      closeSync(this.fd)
    }
  }
}
