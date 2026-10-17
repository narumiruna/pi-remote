import Darwin
import Foundation
import PiRemoteCore

/// Local display hints only. These values are not part of the remote protocol or catalog.
public struct SessionDisplayMetadata: Sendable, Equatable {
    public var name: String?
    public var firstInstruction: String?
    public init(name: String? = nil, firstInstruction: String? = nil) {
        self.name = name; self.firstInstruction = firstInstruction
    }
}

/// Read only companion-owned files supplied by HostCoordinator, never a remote path.
actor SessionHistory {
    private struct Reference {
        var session: UUID
        var file: URL
        var identity: String
        var end: UInt64
        var created = ProcessInfo.processInfo.systemUptime
        var revision: String?
    }
    private struct IndexKey: Hashable { var session: UUID; var file: URL }
    private struct RecordLocation { var start: UInt64; var length: Int }
    private struct InspectionIndex {
        var reference: Reference
        var records: [String: RecordLocation]
        var used = ProcessInfo.processInfo.systemUptime
    }
    private struct FileState: Equatable {
        var identity: String
        var size: UInt64
        var seconds: Int
        var nanoseconds: Int
        var revision: String { "\(identity):\(size):\(seconds):\(nanoseconds)" }
    }
    private struct DisplayCache {
        var state: FileState
        var metadata: SessionDisplayMetadata
        var used: TimeInterval
    }
    private var displayCache: [URL: DisplayCache] = [:]
    private var indexes: [IndexKey: InspectionIndex] = [:]
    // Internal read accounting supports deterministic resource-bound tests, not diagnostics.
    private(set) var displayMetadataBytesRead: UInt64 = 0
    private(set) var inspectionIndexBuilds = 0
    private(set) var inspectionIndexBytesRead: UInt64 = 0
    var inspectionIndexCount: Int { indexes.count }
    private struct EntryReference { var file: Reference; var start: UInt64; var length: Int }
    private var cursors: [UUID: Reference] = [:]
    private var entries: [UUID: EntryReference] = [:]
    private let maximumRecord = 8 * 1_024 * 1_024

    /// Scan at most 2 MiB. A prefix can supply the first instruction, but never
    /// an authoritative name: an unread session_info entry could rename it.
    func displayMetadata(file: URL, root: URL? = nil, piID: String? = nil,
                         directory: RegisteredPath? = nil, parentFile: URL? = nil) throws -> SessionDisplayMetadata {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        displayCache = displayCache.filter { now - $0.value.used < 300 }
        let handle = try openDisplayFile(file, root: root)
        defer { try? handle.close() }
        let state = try fileState(handle)
        // Validate the same descriptor before using even a cached result.
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        displayMetadataBytesRead &+= UInt64(prefix.count)
        guard let end = prefix.firstIndex(of: 10),
              let validatedHeader = try? JSONDecoder().decode(JSONValue.self, from: prefix[..<end]),
              validatedHeader["type"]?.string == "session" else { throw RemoteFault.incompatiblePi }
        if let piID {
            guard validatedHeader["id"]?.string == piID,
                  let cwd = validatedHeader["cwd"]?.string, cwd.hasPrefix("/"),
                  (try? DirectoryRegistry.identify(URL(fileURLWithPath: cwd))) == directory,
                  parentFile == nil || validatedHeader["parentSession"]?.string == parentFile?.path else { throw RemoteFault.incompatiblePi }
        }
        guard try fileState(handle) == state else { throw RemoteFault.staleDirectory }
        if var cached = displayCache[file], cached.state == state {
            cached.used = now; displayCache[file] = cached
            return cached.metadata
        }
        let count = Int(min(state.size, 2 * 1_024 * 1_024))
        var data = prefix
        if data.count < count {
            let remainder = try handle.read(upToCount: count - data.count) ?? Data()
            displayMetadataBytesRead &+= UInt64(remainder.count)
            data.append(remainder)
        }
        guard data.count == count else { throw RemoteFault.staleDirectory }
        var metadata = SessionDisplayMetadata(), start = data.startIndex
        var header = false
        func consume(_ line: Data.SubSequence) throws {
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: line) else { throw RemoteFault.incompatiblePi }
            if !header {
                guard raw["type"]?.string == "session" else { throw RemoteFault.incompatiblePi }
                header = true
            } else if raw["type"]?.string == "session_info" {
                // An empty latest name clears an earlier name.
                metadata.name = Self.displayText(raw["name"]?.string)
            } else if metadata.firstInstruction == nil, raw["type"]?.string == "message",
                      raw["message"]?["role"]?.string == "user" {
                let content = raw["message"]?["content"]
                let text = content?.string ?? content?.array?.compactMap { block in
                    block["type"]?.string == "text" ? block["text"]?.string : nil
                }.joined(separator: " ")
                metadata.firstInstruction = Self.displayText(text)
            }
        }
        while let end = data[start...].firstIndex(of: 10) {
            try Task.checkCancellation()
            try consume(data[start..<end])
            start = data.index(after: end)
        }
        let complete = UInt64(data.count) == state.size
        var validTail = true
        if complete, start != data.endIndex {
            do { try consume(data[start...]) }
            catch { validTail = false }
        }
        guard header, try fileState(handle) == state else { throw RemoteFault.staleDirectory }
        if !complete || !validTail { metadata.name = nil }
        displayCache[file] = DisplayCache(state: state, metadata: metadata, used: now)
        while displayCache.count > 256, let oldest = displayCache.min(by: { $0.value.used < $1.value.used })?.key {
            displayCache.removeValue(forKey: oldest)
        }
        return metadata
    }

    /// Walk from / with no-follow directory descriptors. No parent symlink can
    /// redirect a metadata read outside companion-owned storage.
    private func openDisplayFile(_ file: URL, root: URL?) throws -> FileHandle {
        let path = file.standardizedFileURL.path
        if let root {
            guard path.hasPrefix(root.standardizedFileURL.path + "/"), file.pathExtension == "jsonl" else { throw RemoteFault.incompatiblePi }
        }
        // Darwin exposes these system-owned aliases. Expand only these fixed
        // prefixes; never resolve user-controlled storage components.
        let traversalPath = path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        let parts = traversalPath.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty else { throw RemoteFault.permissionDenied }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (index == parts.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(descriptor, part, flags)
            close(descriptor)
            guard next >= 0 else { throw RemoteFault.permissionDenied }
            descriptor = next
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func displayText(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.isEmpty ? nil : DisplayLimit.text(normalized, bytes: 4_096)
    }

    func page(session: UUID, file: URL?, cursor: UUID?) throws -> HistoryPage {
        expire()
        defer { trim() }
        guard let file else {
            if cursor != nil { throw RemoteFault.expired }
            return HistoryPage(items: [], next: nil)
        }
        let handle = try openFile(file)
        defer { try? handle.close() }
        let (identity, size) = try fingerprint(handle)
        guard size > 0 else { throw RemoteFault.incompatiblePi }
        var reference: Reference
        if let cursor {
            guard let saved = cursors[cursor], saved.session == session,
                  saved.file == file, saved.identity == identity, saved.end <= size else { throw RemoteFault.expired }
            reference = saved
        } else {
            reference = Reference(session: session, file: file, identity: identity, end: size)
            // Ignore an incomplete append. It can be included after a fresh first-page request.
            if size > 0 {
                try handle.seek(toOffset: size - 1)
                if try handle.read(upToCount: 1) != Data([10]) {
                    let partial = try line(handle, endingAt: size)
                    reference.end = partial.start
                    guard reference.end > 0 else { throw RemoteFault.incompatiblePi }
                }
            }
        }
        var items: [HistoryItem] = []
        var readBytes = 0
        while reference.end > 0, items.count < 100, readBytes < maximumRecord {
            try Task.checkCancellation()
            let record = try line(handle, endingAt: reference.end)
            reference.end = record.start
            readBytes += record.data.count + 1
            guard !record.data.isEmpty else { throw RemoteFault.incompatiblePi }
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: record.data),
                  let kind = raw["type"]?.string, kind.utf8.count <= 128,
                  (raw["parentId"]?.string?.utf8.count ?? 0) <= 128 else { throw RemoteFault.incompatiblePi }
            if kind == "session" { reference.end = 0; break }
            guard let id = raw["id"]?.string, !id.isEmpty, id.utf8.count <= 128 else { throw RemoteFault.incompatiblePi }
            let token = UUID()
            entries[token] = EntryReference(file: reference, start: record.start, length: record.data.count)
            let normalized = try Self.message(in: raw)
            let message = normalized.flatMap(TranscriptReducer.message)
            let summary = message.flatMap { $0.text.isEmpty ? $0.thinking : $0.text } ??
                (Self.visible(normalized) ? raw["summary"]?.string : nil) ?? kind
            items.append(HistoryItem(id: id, parent: raw["parentId"]?.string, kind: kind,
                                     text: DisplayLimit.text(summary, bytes: 512),
                                     canFork: false, preview: token))
        }
        var next: UUID?
        if reference.end > 0 {
            next = UUID(); reference.created = ProcessInfo.processInfo.systemUptime
            cursors[next!] = reference
        }
        return HistoryPage(items: items, next: next)
    }

    func preview(session: UUID, id: UUID) throws -> FilePreview {
        try displayEntry(session: session, id: id).preview
    }

    func displayEntry(session: UUID, id: UUID) throws -> (preview: FilePreview, message: JSONValue?) {
        expire()
        guard let entry = entries[id], entry.file.session == session else { throw RemoteFault.expired }
        let handle = try openFile(entry.file.file)
        defer { try? handle.close() }
        let (identity, size) = try fingerprint(handle)
        guard identity == entry.file.identity, size >= entry.start + UInt64(entry.length) else { throw RemoteFault.staleDirectory }
        try handle.seek(toOffset: entry.start)
        guard let data = try handle.read(upToCount: entry.length), data.count == entry.length,
              let raw = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw RemoteFault.incompatiblePi }
        if let revision = entry.file.revision, try fileState(handle).revision != revision { throw RemoteFault.staleDirectory }
        let message = try Self.message(in: raw)
        let thinking = (message?["content"]?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "thinking", block["redacted"]?.bool != true else { return nil }
            return block["thinking"]?.string
        }.joined(separator: "\n")
        let visible = Self.visible(message)
        var body = visible ? TranscriptReducer.content(message?["content"]) : ""
        if body.isEmpty { body = (visible ? raw["summary"]?.string ?? message?["output"]?.string ?? message?["errorMessage"]?.string : nil) ?? "No display text for this entry." }
        if visible, !thinking.isEmpty { body = "Thinking\n" + thinking + "\n\n" + body }
        let preview = FilePreview(name: raw["type"]?.string ?? "History entry", text: DisplayLimit.text(body, bytes: 256 * 1_024), truncated: body.utf8.count > 256 * 1_024)
        return (preview, visible ? message : nil)
    }

    private static func message(in entry: JSONValue) throws -> JSONValue? {
        guard entry["type"]?.string == "custom_message" else { return entry["message"] }
        guard let content = entry["content"], content.string != nil || content.array != nil,
              entry["display"] == nil || entry["display"]?.bool != nil else { throw RemoteFault.incompatiblePi }
        return .object(["role": .string("custom"), "content": content,
                        "display": entry["display"] ?? .bool(true)])
    }

    private static func visible(_ message: JSONValue?) -> Bool {
        message?["role"]?.string != "system" && !(message?["role"]?.string == "custom" && message?["display"]?.bool == false)
    }

    /// Internal identity for inspection invalidation. Never sent to a remote client.
    func revision(file: URL?) throws -> String? {
        guard let file else { return nil }
        let handle = try openFile(file)
        defer { try? handle.close() }
        return try fileState(handle).revision
    }

    /// Index each unchanged file once, retaining only IDs and offsets. At most two
    /// session/file indexes live for five minutes; each holds at most 10,000 entries.
    func inspectionPreviews(session: UUID, file: URL?, ids: Set<String>) throws -> [String: UUID] {
        try Task.checkCancellation()
        expire()
        defer { trim() }
        guard ids.count <= 100 else { throw RemoteFault.tooLarge }
        guard let file else { return [:] }
        let handle = try openFile(file)
        defer { try? handle.close() }
        let state = try fileState(handle), key = IndexKey(session: session, file: file)
        var index: InspectionIndex
        if let cached = indexes[key], cached.reference.revision == state.revision { index = cached }
        else {
            indexes.removeValue(forKey: key)
            index = try buildIndex(handle, session: session, file: file, state: state)
        }
        guard try fileState(handle) == state else { throw RemoteFault.staleDirectory }
        index.used = ProcessInfo.processInfo.systemUptime
        indexes[key] = index
        var reference = index.reference
        reference.created = ProcessInfo.processInfo.systemUptime
        var result: [String: UUID] = [:]
        for id in ids {
            if let record = index.records[id] {
                let token = UUID()
                entries[token] = EntryReference(file: reference, start: record.start, length: record.length)
                result[id] = token
            }
        }
        return result
    }

    private func buildIndex(_ handle: FileHandle, session: UUID, file: URL, state: FileState) throws -> InspectionIndex {
        guard state.size > 0 else { throw RemoteFault.incompatiblePi }
        guard state.size <= 32 * 1_024 * 1_024 else { throw RemoteFault.tooLarge }
        inspectionIndexBuilds &+= 1
        var records: [String: RecordLocation] = [:]
        var buffer = Data(), position: UInt64 = 0, recordStart: UInt64 = 0
        var header = false
        func consume() throws {
            guard !buffer.isEmpty, let raw = try? JSONDecoder().decode(JSONValue.self, from: buffer),
                  let kind = raw["type"]?.string, kind.utf8.count <= 128 else { throw RemoteFault.incompatiblePi }
            if !header {
                guard kind == "session" else { throw RemoteFault.incompatiblePi }
                header = true
            } else {
                guard kind != "session", let id = raw["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
                      records[id] == nil else { throw RemoteFault.incompatiblePi }
                guard records.count < SessionInspectionMapper.maximumItems else { throw RemoteFault.tooLarge }
                records[id] = RecordLocation(start: recordStart, length: buffer.count)
            }
        }
        try handle.seek(toOffset: 0)
        while position < state.size {
            try Task.checkCancellation()
            let length = Int(min(65_536, state.size - position))
            guard let chunk = try handle.read(upToCount: length), chunk.count == length else { throw RemoteFault.staleDirectory }
            inspectionIndexBytesRead &+= UInt64(chunk.count)
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 10) {
                try Task.checkCancellation()
                guard buffer.count + end - start <= maximumRecord else { throw RemoteFault.tooLarge }
                buffer.append(contentsOf: chunk[start..<end])
                try consume()
                buffer.removeAll(keepingCapacity: true)
                recordStart = position + UInt64(end) + 1
                start = chunk.index(after: end)
            }
            guard buffer.count + chunk.count - start <= maximumRecord else { throw RemoteFault.tooLarge }
            buffer.append(contentsOf: chunk[start...])
            position += UInt64(chunk.count)
        }
        if !buffer.isEmpty { try consume() }
        return InspectionIndex(reference: Reference(session: session, file: file, identity: state.identity,
                                                    end: state.size, revision: state.revision), records: records)
    }

    private func openFile(_ file: URL) throws -> FileHandle {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private func fileState(_ file: FileHandle) throws -> FileState {
        var value = stat()
        guard fstat(file.fileDescriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw RemoteFault.staleDirectory }
        return FileState(identity: "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)",
                         size: UInt64(value.st_size), seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
    }
    private func fingerprint(_ file: FileHandle) throws -> (String, UInt64) {
        let state = try fileState(file)
        return (state.identity, state.size)
    }
    private func line(_ file: FileHandle, endingAt end: UInt64) throws -> (data: Data, start: UInt64) {
        var end = end
        if end > 0 {
            try file.seek(toOffset: end - 1)
            if try file.read(upToCount: 1) == Data([10]) { end -= 1 }
        }
        var position = end, parts: [Data] = [], count = 0
        while position > 0 {
            try Task.checkCancellation()
            let length = Int(min(position, 65_536)), start = position - UInt64(min(position, 65_536))
            try file.seek(toOffset: start)
            guard let data = try file.read(upToCount: length), data.count == length else { throw RemoteFault.staleDirectory }
            let split = data.lastIndex(of: 10)
            let tail = split.map { Data(data[data.index(after: $0)...]) } ?? data
            count += tail.count
            guard count <= maximumRecord else { throw RemoteFault.tooLarge }
            parts.append(tail)
            position = split.map { start + UInt64($0) + 1 } ?? start
            if split != nil { break }
        }
        var result = Data(capacity: count)
        for part in parts.reversed() { result.append(part) }
        if result.last == 13 { result.removeLast() }
        return (result, position)
    }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        cursors = cursors.filter { now - $0.value.created < 300 }
        entries = entries.filter { now - $0.value.file.created < 300 }
        indexes = indexes.filter { now - $0.value.reference.created < 300 }
    }
    private func trim() {
        while indexes.count > 2, let oldest = indexes.min(by: { $0.value.used < $1.value.used })?.key { indexes.removeValue(forKey: oldest) }
        while cursors.count > 8, let oldest = cursors.min(by: { $0.value.created < $1.value.created })?.key { cursors.removeValue(forKey: oldest) }
        while entries.count > 2_000, let oldest = entries.min(by: { $0.value.file.created < $1.value.file.created })?.key { entries.removeValue(forKey: oldest) }
    }
}
