import Darwin
import Foundation
import PiRemoteCore

/// Read only companion-owned files supplied by HostCoordinator, never a remote path.
actor SessionHistory {
    private struct Reference {
        var session: UUID
        var file: URL
        var identity: String
        var end: UInt64
        var created = ProcessInfo.processInfo.systemUptime
    }
    private struct EntryReference { var file: Reference; var start: UInt64; var length: Int }
    private var cursors: [UUID: Reference] = [:]
    private var entries: [UUID: EntryReference] = [:]
    private let maximumRecord = 8 * 1_024 * 1_024

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
            let message = raw["message"].flatMap(TranscriptReducer.message)
            let summary = message.flatMap { $0.text.isEmpty ? $0.thinking : $0.text } ?? raw["summary"]?.string ?? kind
            items.append(HistoryItem(id: id, parent: raw["parentId"]?.string, kind: kind,
                                     text: DisplayLimit.text(summary, bytes: 512),
                                     canFork: raw["message"]?["role"]?.string == "user", preview: token))
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
        let message = raw["message"]
        let thinking = (message?["content"]?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "thinking", block["redacted"]?.bool != true else { return nil }
            return block["thinking"]?.string
        }.joined(separator: "\n")
        let visible = message?["role"]?.string != "system" && !(message?["role"]?.string == "custom" && message?["display"]?.bool == false)
        var body = visible ? TranscriptReducer.content(message?["content"]) : ""
        if body.isEmpty { body = raw["summary"]?.string ?? (visible ? message?["output"]?.string ?? message?["errorMessage"]?.string : nil) ?? "No display text for this entry." }
        if visible, !thinking.isEmpty { body = "Thinking\n" + thinking + "\n\n" + body }
        let preview = FilePreview(name: raw["type"]?.string ?? "History entry", text: DisplayLimit.text(body, bytes: 256 * 1_024), truncated: body.utf8.count > 256 * 1_024)
        return (preview, visible ? message : nil)
    }

    private func openFile(_ file: URL) throws -> FileHandle {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private func fingerprint(_ file: FileHandle) throws -> (String, UInt64) {
        var value = stat()
        guard fstat(file.fileDescriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw RemoteFault.staleDirectory }
        return ("\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)", UInt64(value.st_size))
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
    }
    private func trim() {
        while cursors.count > 8, let oldest = cursors.min(by: { $0.value.created < $1.value.created })?.key { cursors.removeValue(forKey: oldest) }
        while entries.count > 2_000, let oldest = entries.min(by: { $0.value.file.created < $1.value.file.created })?.key { entries.removeValue(forKey: oldest) }
    }
}
