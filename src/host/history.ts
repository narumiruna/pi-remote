import { constants, realpathSync } from "node:fs"
import { type FileHandle, lstat, open, realpath } from "node:fs/promises"
import { resolve, sep } from "node:path"
import { Fault } from "./storage.ts"
import { TRANSCRIPT_LIMITS } from "./transcript.ts"

export const SESSION_HISTORY_BYTES = 64 * 1024 * 1024

type Entry = Record<string, unknown>
type Indexed = { id: string; parentId: string | null; start: number; end: number }

/** Read only after Pi has loaded the session and migrated legacy JSONL itself.
 * Pi 1.3.0: session-manager.js _buildIndex/buildContextEntries/buildSessionProjection.
 * get_messages and get_entries have no response-size limit or bounded page option.
 * This is a display projection. It never writes history or replaces Pi's model context.
 */
export async function readSessionHistory(options: {
  folder: string
  file?: string
  id: string
  cwd: string
  required: boolean
}): Promise<unknown[] | undefined> {
  if (!options.file) {
    if (options.required) throw new Fault("incompatiblePi")
    return undefined
  }
  const folder = await realpath(options.folder)
  if (folder !== resolve(options.folder)) throw new Fault("unsafeStorage")
  const directory = await lstat(folder)
  if (
    !directory.isDirectory() ||
    directory.uid !== process.getuid?.() ||
    (directory.mode & 0o7777) !== 0o700
  )
    throw new Fault("unsafeStorage")
  const file = resolve(options.file)
  if (!file.startsWith(folder + sep) || !file.endsWith(".jsonl")) throw new Fault("unsafeStorage")
  // Pi does not create a new session file until it has conversation messages.
  let handle: FileHandle
  try {
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
  } catch (error) {
    if (!options.required && (error as NodeJS.ErrnoException).code === "ENOENT") return undefined
    throw new Fault("unsafeStorage")
  }
  try {
    if (!(await realpath(file)).startsWith(folder + sep)) throw new Fault("unsafeStorage")
    const before = await handle.stat({ bigint: true })
    if (
      !before.isFile() ||
      before.uid !== BigInt(process.getuid?.() ?? -1) ||
      before.nlink !== 1n ||
      (before.mode & 0o022n) !== 0n
    )
      throw new Fault("unsafeStorage")
    if (before.size > BigInt(SESSION_HISTORY_BYTES)) throw new Fault("tooLarge")
    const bytes = Buffer.alloc(Number(before.size) + 1)
    let size = 0
    while (size < bytes.length) {
      const result = await handle.read(bytes, size, bytes.length - size, null)
      if (!result.bytesRead) break
      size += result.bytesRead
    }
    const after = await handle.stat({ bigint: true })
    const current = await lstat(file, { bigint: true })
    const currentDirectory = await lstat(folder)
    if (size > SESSION_HISTORY_BYTES || after.size > BigInt(SESSION_HISTORY_BYTES))
      throw new Fault("tooLarge")
    if (
      BigInt(size) !== before.size ||
      before.size !== after.size ||
      before.mtimeNs !== after.mtimeNs ||
      before.ctimeNs !== after.ctimeNs ||
      current.dev !== after.dev ||
      current.ino !== after.ino ||
      current.size !== after.size ||
      current.mtimeNs !== after.mtimeNs ||
      current.ctimeNs !== after.ctimeNs ||
      currentDirectory.dev !== directory.dev ||
      currentDirectory.ino !== directory.ino
    )
      throw new Fault("conflict")
    return projectHistory(bytes.subarray(0, size), options.id, options.cwd)
  } finally {
    await handle.close()
  }
}

function record(value: unknown): value is Entry {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function canonicalDirectory(path: string): string | undefined {
  try {
    return realpathSync(path)
  } catch {
    return undefined
  }
}

function projectHistory(bytes: Buffer, id: string, cwd: string): unknown[] {
  // Keep offsets, not parsed message bodies, in the tree index. A single record
  // can be large, but the whole read is bounded by SESSION_HISTORY_BYTES.
  const byID = new Map<string, Indexed>()
  let header: Entry | undefined
  let leaf: Indexed | undefined
  const parse = (start: number, end: number): Entry | undefined => {
    try {
      const value: unknown = JSON.parse(bytes.toString("utf8", start, end))
      return record(value) ? value : undefined
    } catch {
      // Pi's loadEntriesFromFile also skips malformed and blank lines.
      return undefined
    }
  }
  for (let start = 0; start < bytes.length; ) {
    const newline = bytes.indexOf(10, start)
    const end = newline < 0 ? bytes.length : newline
    const entry = parse(start, end)
    if (entry) {
      if (!header) {
        header = entry
        if (
          header.type !== "session" ||
          header.version !== 3 ||
          header.id !== id ||
          typeof header.cwd !== "string" ||
          canonicalDirectory(header.cwd) !== cwd
        )
          throw new Fault("incompatiblePi")
      } else if (entry.type !== "session") {
        if (
          typeof entry.id !== "string" ||
          !(entry.parentId === null || typeof entry.parentId === "string")
        )
          throw new Fault("incompatiblePi")
        leaf = { id: entry.id, parentId: entry.parentId, start, end }
        byID.set(leaf.id, leaf)
      }
    }
    start = end + 1
  }
  if (!header) throw new Fault("incompatiblePi")
  const path: Indexed[] = []
  const visited = new Set<string>()
  // On load, Pi 1.3.0 selects the last non-header entry, including metadata.
  while (leaf) {
    if (visited.has(leaf.id)) throw new Fault("incompatiblePi")
    visited.add(leaf.id)
    path.push(leaf)
    leaf = leaf.parentId ? byID.get(leaf.parentId) : undefined
  }
  path.reverse()
  const read = (item: Indexed): Entry => parse(item.start, item.end) ?? {}
  let compactionIndex = -1
  for (const [index, item] of path.entries()) {
    if (read(item).type === "compaction") compactionIndex = index
  }
  let selected = path
  const compaction = path[compactionIndex]
  if (compaction) {
    const firstKept = read(compaction).firstKeptEntryId
    const keptIndex = path.findIndex((item) => item.id === firstKept)
    selected = [
      compaction,
      ...(keptIndex >= 0 && keptIndex < compactionIndex
        ? path.slice(keptIndex, compactionIndex).filter((item) => {
            const entry = read(item)
            return !(
              entry.type === "message" &&
              record(entry.message) &&
              entry.message.role === "system"
            )
          })
        : []),
      ...path.slice(compactionIndex + 1),
    ]
  }
  const edits = new Map<string, Entry>()
  for (const item of selected) {
    const entry = read(item)
    if (entry.type === "context_edit" && typeof entry.targetId === "string")
      edits.set(entry.targetId, entry)
  }
  const messages: unknown[] = []
  for (const [index, item] of selected.entries()) {
    const entry = read(item)
    let projected: Entry[] = []
    const timestamp = new Date(String(entry.timestamp)).getTime()
    if (entry.type === "message" && record(entry.message)) {
      const message = entry.message
      projected = [
        message.content == null &&
        ["system", "user", "assistant", "toolResult"].includes(String(message.role))
          ? { ...message, content: message.role === "system" ? "" : [] }
          : message,
      ]
    } else if (entry.type === "custom_message") {
      projected = [
        {
          role: "custom",
          customType: entry.customType,
          content: entry.content ?? [],
          display: entry.display,
          details: entry.details,
          timestamp,
        },
      ]
    } else if (entry.type === "branch_summary" && entry.summary) {
      projected = [
        { role: "branchSummary", summary: entry.summary, fromId: entry.fromId, timestamp },
      ]
    } else if (entry.type === "compaction" && index === 0) {
      if (record(entry.systemMessage)) projected.push(entry.systemMessage)
      projected.push({
        role: "compactionSummary",
        summary: entry.summary,
        tokensBefore: entry.tokensBefore,
        timestamp,
      })
    }
    const edit = edits.get(item.id)
    if (edit) {
      if (edit.replacement === null) projected = []
      else if (record(edit.replacement)) {
        const replacement = edit.replacement
        projected = projected.map((message) => {
          if (!["user", "assistant", "toolResult", "custom"].includes(String(message.role)))
            return message
          return {
            ...message,
            content:
              ["assistant", "toolResult"].includes(String(message.role)) &&
              typeof replacement.content === "string"
                ? [{ type: "text", text: replacement.content }]
                : replacement.content,
          }
        })
      }
    }
    messages.push(...projected)
    // One extra message retains the reducer's explicit omitted-history signal.
    if (messages.length > TRANSCRIPT_LIMITS.messages + 1)
      messages.splice(0, messages.length - TRANSCRIPT_LIMITS.messages - 1)
  }
  return messages
}
