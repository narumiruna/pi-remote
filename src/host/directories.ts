import { dlopen, type Pointer, ptr, toArrayBuffer } from "bun:ffi"
import { randomUUID } from "node:crypto"
import {
  accessSync,
  closeSync,
  constants,
  fstatSync,
  openSync,
  realpathSync,
  statSync,
} from "node:fs"
import { homedir } from "node:os"
import { dirname, isAbsolute, join } from "node:path"
import { faultCode } from "./errors.ts"
import type { RemoteFault } from "./protocol.ts"
import { Fault } from "./storage.ts"

export interface DirectoryRecord {
  path: string
  identity: string
}
export interface DirectoryItem {
  id: string
  name: string
  isDirectory: boolean
  fault?: RemoteFault
}
export interface DirectoryPage {
  id: string
  path: string
  parent?: string
  items: DirectoryItem[]
  next?: string
}
interface Node {
  record: DirectoryRecord
  touched: number
}
interface Cursor {
  directory: string
  iterator: DirectoryIterator
  created: number
}

let enumeration: ReturnType<typeof openEnumeration> | undefined
function openEnumeration() {
  const mac = process.platform === "darwin"
  if (!mac && process.platform !== "linux") throw new Fault("unsupportedFeature")
  return dlopen(mac ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
    openat: { args: ["i32", "ptr", "i32", "u32"], returns: "i32" },
    fdopendir: { args: ["i32"], returns: "ptr" },
    readdir: { args: ["ptr"], returns: "ptr" },
    closedir: { args: ["ptr"], returns: "i32" },
    [mac ? "__error" : "__errno_location"]: { args: [], returns: "ptr" },
  })
}
class DirectoryIterator {
  private handle: Pointer | bigint | null
  constructor(fd: number) {
    enumeration ??= openEnumeration()
    const dot = Buffer.from(".\0")
    const duplicate = enumeration.symbols.openat(
      fd,
      ptr(dot),
      constants.O_RDONLY |
        constants.O_DIRECTORY |
        constants.O_NOFOLLOW |
        (process.platform === "darwin" ? 0x1000000 : 0x80000),
      0,
    )
    if (duplicate < 0) throw iteratorFault()
    this.handle = enumeration.symbols.fdopendir(duplicate)
    if (!this.handle) {
      const error = iteratorFault()
      closeSync(duplicate)
      throw error
    }
  }
  readSync(): { name: string } | null {
    if (!this.handle || !enumeration) throw new Fault("staleDirectory")
    const errno = iteratorErrno()
    errno[0] = 0
    const entry = enumeration.symbols.readdir(this.handle)
    if (!entry) {
      if (errno[0] !== 0) throw new Fault("permissionDenied")
      return null
    }
    const header = Buffer.from(toArrayBuffer(entry, 0, 21))
    const length = header.readUInt16LE(16)
    const offset = process.platform === "darwin" ? 21 : 19
    if (length <= offset || length > 2048) throw new Fault("unsupportedFeature")
    const data = Buffer.from(toArrayBuffer(entry, offset, length - offset))
    const end = data.indexOf(0)
    if (end < 0) throw new Fault("unsupportedFeature")
    const name = new TextDecoder("utf-8", { fatal: true }).decode(data.subarray(0, end))
    if (name === "." || name === "..") return this.readSync()
    return { name }
  }
  closeSync() {
    if (this.handle && enumeration) {
      enumeration.symbols.closedir(this.handle)
      this.handle = null
    }
  }
}

function iteratorErrno(): Int32Array {
  const pointer =
    enumeration?.symbols[process.platform === "darwin" ? "__error" : "__errno_location"]()
  if (!pointer) throw new Fault("unsupportedFeature")
  return new Int32Array(toArrayBuffer(pointer, 0, 4))
}
function iteratorFault(): Fault {
  const errno = iteratorErrno()[0]
  return new Fault(errno === 23 || errno === 24 ? "resourceLimit" : "permissionDenied")
}

let linux: ReturnType<typeof openStatx> | undefined
function openStatx() {
  try {
    return dlopen("libc.so.6", {
      statx: { args: ["i32", "ptr", "i32", "u32", "ptr"], returns: "i32" },
    })
  } catch {
    throw new Fault(
      "unsupportedFeature",
      "Directory identity requires Linux statx birth time support.",
    )
  }
}
function identity(fd: number): string {
  const info = fstatSync(fd, { bigint: true })
  if (!info.isDirectory()) throw new Fault("staleDirectory")
  let birth: string
  if (process.platform === "linux") {
    linux ??= openStatx()
    const output = Buffer.alloc(256)
    const empty = Buffer.from([0])
    // AT_EMPTY_PATH reads this live descriptor. STATX_BTIME must be present.
    if (
      linux.symbols.statx(fd, ptr(empty), 0x1000, 0x800, ptr(output)) !== 0 ||
      (output.readUInt32LE(0) & 0x800) === 0 ||
      output.readBigInt64LE(80) <= 0n ||
      output.readUInt32LE(88) >= 1_000_000_000
    ) {
      throw new Fault(
        "unsupportedFeature",
        "This filesystem does not expose stable directory birth times; select another filesystem.",
      )
    }
    birth = `${output.readBigInt64LE(80)}:${output.readUInt32LE(88)}`
  } else if (process.platform === "darwin") {
    if (info.birthtimeNs <= 0n)
      throw new Fault(
        "unsupportedFeature",
        "This filesystem does not expose stable directory birth times.",
      )
    birth = info.birthtimeNs.toString()
  } else throw new Fault("unsupportedFeature")
  return `${info.dev}:${info.ino}:${birth}`
}
function mapped(error: unknown): never {
  if (error instanceof Fault) throw error
  const code = (error as NodeJS.ErrnoException).code
  if (code === "EACCES" || code === "EPERM") throw new Fault("permissionDenied")
  if (code === "EMFILE" || code === "ENFILE")
    throw new Fault(
      "resourceLimit",
      "The host cannot hold more directory handles. Close unused files or increase the process file limit.",
    )
  throw new Fault("staleDirectory")
}
function opened(path: string): { record: DirectoryRecord; fd: number } {
  let fd: number | undefined
  try {
    const canonical = realpathSync(path)
    fd = openSync(
      canonical,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    )
    const record = { path: canonical, identity: identity(fd) }
    accessSync(canonical, constants.R_OK | constants.X_OK)
    const current = statSync(canonical, { bigint: true })
    const actual = fstatSync(fd, { bigint: true })
    if (current.dev !== actual.dev || current.ino !== actual.ino) throw new Fault("staleDirectory")
    return { record, fd }
  } catch (error) {
    if (fd !== undefined) closeSync(fd)
    return mapped(error)
  }
}

/** Directory IDs authorize host-side resolution, never shell or tools containment. */
export class DirectoryAccess {
  private readonly nodes = new Map<string, Node>()
  private readonly cursors = new Map<string, Cursor>()
  private readonly initialPath: string
  private closed = false

  constructor(initialPath: string) {
    this.initialPath = initialPath
  }

  static async identify(path: string): Promise<DirectoryRecord> {
    const node = opened(path)
    closeSync(node.fd)
    return node.record
  }

  static async validate(record: DirectoryRecord): Promise<DirectoryRecord> {
    if (
      !record ||
      typeof record.path !== "string" ||
      typeof record.identity !== "string" ||
      !isAbsolute(record.path)
    )
      throw new Fault("staleDirectory")
    const current = await DirectoryAccess.identify(record.path)
    if (current.path !== record.path || current.identity !== record.identity)
      throw new Fault("staleDirectory")
    return current
  }

  private evict(): void {
    const pinned = new Set([...this.cursors.values()].map((cursor) => cursor.directory))
    let oldest: string | undefined
    let age = Number.POSITIVE_INFINITY
    for (const [id, node] of this.nodes) {
      if (!pinned.has(id) && node.touched < age) {
        oldest = id
        age = node.touched
      }
    }
    if (!oldest) throw new Fault("resourceLimit")
    this.nodes.delete(oldest)
  }

  private register(path: string): string {
    const openedNode = opened(path)
    closeSync(openedNode.fd)
    for (const [id, node] of this.nodes) {
      if (
        node.record.path === openedNode.record.path &&
        node.record.identity === openedNode.record.identity
      ) {
        node.touched = performance.now()
        return id
      }
    }
    if (this.nodes.size >= 4096) this.evict()
    const id = randomUUID().toUpperCase()
    this.nodes.set(id, { record: openedNode.record, touched: performance.now() })
    return id
  }

  private openNode(id: string): { record: DirectoryRecord; fd: number } {
    this.check()
    const node = this.nodes.get(id)
    if (!node) throw new Fault("staleDirectory")
    const current = opened(node.record.path)
    if (
      current.record.path !== node.record.path ||
      current.record.identity !== node.record.identity
    ) {
      closeSync(current.fd)
      throw new Fault("staleDirectory")
    }
    node.touched = performance.now()
    return current
  }

  private resolveSync(id: string): DirectoryRecord {
    const current = this.openNode(id)
    closeSync(current.fd)
    return current.record
  }

  async resolve(id: string): Promise<DirectoryRecord> {
    return this.resolveSync(id)
  }

  private check() {
    if (this.closed) throw new Fault("staleDirectory")
  }
  private discard(token: string) {
    const cursor = this.cursors.get(token)
    if (cursor) {
      try {
        cursor.iterator.closeSync()
      } finally {
        this.cursors.delete(token)
      }
    }
  }

  async atPath(path: string): Promise<DirectoryPage> {
    this.check()
    if (!path || Buffer.byteLength(path) > 4096 || path.includes("\0"))
      throw new Fault("invalidRequest")
    const expanded =
      path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path
    if (!isAbsolute(expanded)) throw new Fault("invalidRequest")
    return this.list(this.register(expanded))
  }

  async list(id?: string, cursor?: string): Promise<DirectoryPage> {
    this.check()
    for (const [token, item] of this.cursors)
      if (performance.now() - item.created >= 60_000) this.discard(token)
    const selected = id ?? this.register(this.initialPath)
    let record: DirectoryRecord
    let token = cursor
    let iterator: DirectoryIterator
    if (token !== undefined) {
      const saved = this.cursors.get(token)
      if (!saved || saved.directory !== selected) throw new Fault("staleDirectory")
      record = this.resolveSync(selected)
      iterator = saved.iterator
    } else {
      const current = this.openNode(selected)
      record = current.record
      try {
        if (this.cursors.size >= 8) {
          const oldest = this.cursors.keys().next().value
          if (oldest) this.discard(oldest)
        }
        // The iterator owns a duplicate of this exact validated directory descriptor.
        iterator = new DirectoryIterator(current.fd)
      } catch (error) {
        return mapped(error)
      } finally {
        closeSync(current.fd)
      }
      token = randomUUID().toUpperCase()
      this.cursors.set(token, { directory: selected, iterator, created: performance.now() })
    }
    const items: DirectoryItem[] = []
    let ended = false
    try {
      for (let examined = 0; examined < 100; examined++) {
        const entry = iterator.readSync()
        if (!entry) {
          ended = true
          break
        }
        try {
          const target = realpathSync(join(record.path, entry.name))
          const info = statSync(target)
          items.push({
            id: info.isDirectory() ? this.register(target) : randomUUID().toUpperCase(),
            name: entry.name,
            isDirectory: info.isDirectory(),
          })
        } catch (error) {
          // An inaccessible or unsupported child is an explicit error row,
          // never a registered directory capability.
          items.push({
            id: randomUUID().toUpperCase(),
            name: entry.name,
            isDirectory: false,
            fault: faultCode(error),
          })
        }
      }
      this.resolveSync(selected)
      const parent = record.path === "/" ? undefined : this.register(dirname(record.path))
      if (ended) this.discard(token)
      items.sort(
        (a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name),
      )
      return { id: selected, path: record.path, parent, items, next: ended ? undefined : token }
    } catch (error) {
      this.discard(token)
      return mapped(error)
    }
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    for (const token of this.cursors.keys()) this.discard(token)
    this.nodes.clear()
  }
}
