import Foundation

public struct SessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var directory: String
    public var updated: Date
    public var interrupted: Bool
    public init(id: UUID, title: String, directory: String, updated: Date = Date(), interrupted: Bool = false) {
        self.id = id; self.title = title; self.directory = directory; self.updated = updated; self.interrupted = interrupted
    }
}

public struct TranscriptMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: String
    public var text: String
    public var thinking: String?
    public var isError: Bool
    public var streaming: Bool
    public var truncated: Bool
    public var images: [OutputImageReference]?
    public init(id: UUID = UUID(), role: String, text: String, thinking: String? = nil, isError: Bool = false, streaming: Bool = false, truncated: Bool = false, images: [OutputImageReference]? = nil) {
        self.id = id; self.role = role; self.text = text; self.thinking = thinking; self.isError = isError
        self.streaming = streaming; self.truncated = truncated; self.images = images
    }
}

public struct ModelOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { provider + "/" + model }
    public var provider: String
    public var model: String
    public var name: String
    public init(provider: String, model: String, name: String) {
        self.provider = provider; self.model = model; self.name = name
    }
}

public struct CommandOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var detail: String
    public var source: String
    public init(name: String, detail: String, source: String) {
        self.name = name; self.detail = detail; self.source = source
    }
}

public struct ExtensionDialog: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var method: String
    public var title: String
    public var message: String
    public var options: [String]
    public var text: String
    public var expires: Date?
    public init(id: String, method: String, title: String, message: String, options: [String], text: String, expires: Date?) {
        self.id = id; self.method = method; self.title = title; self.message = message
        self.options = options; self.text = text; self.expires = expires
    }
}

public struct HostSnapshot: Codable, Sendable, Equatable {
    public var host: UUID
    public var epoch: UUID
    public var sequence: UInt64 = 0
    public var piVersion = "Not running"
    public var capabilities = ["directories", "sessions", "prompt", "steering", "follow-up", "stop", "models", "thinking", "extension-dialogs", "history", "history-pages", "thinking-display", "fork", "clone", "compaction", "file-preview", "git-diff", "images", "session-statistics", "output-images", "last-assistant", "runtime-settings", "close-session", "session-export"]
    public var sessions: [SessionInfo] = []
    public var selected: UUID?
    public var phase = "idle"
    public var messages: [TranscriptMessage] = []
    public var models: [ModelOption] = []
    public var model: String = ""
    public var thinking: String = ""
    public var thinkingLevels: [String] = []
    public var commands: [CommandOption] = []
    public var dialogs: [ExtensionDialog] = []
    public var notices: [String] = []
    public var draft: String?
    public var draftID: UUID?
    public var error: RemoteFault?
    public var hasOlderMessages = false
    public var runtime: RuntimeSettings?

    public init(host: UUID, epoch: UUID) { self.host = host; self.epoch = epoch }

    public var working: Bool { !["idle", "interrupted", "unavailable"].contains(phase) }
    public var context: SessionContext { SessionContext(host: host, epoch: epoch, session: selected) }
}

/// Bind a UI action to the host epoch and session that the user saw.
public struct SessionContext: Sendable, Equatable, Hashable {
    public var host: UUID
    public var epoch: UUID
    public var session: UUID?
    public init(host: UUID, epoch: UUID, session: UUID?) { self.host = host; self.epoch = epoch; self.session = session }
}

public struct DirectoryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isDirectory: Bool
    public var fault: RemoteFault?
    public init(id: UUID, name: String, isDirectory: Bool, fault: RemoteFault? = nil) {
        self.id = id; self.name = name; self.isDirectory = isDirectory; self.fault = fault
    }
}

public struct DirectoryPage: Codable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var parent: UUID?
    public var items: [DirectoryItem]
    public var next: UUID?
    public init(id: UUID, path: String, parent: UUID?, items: [DirectoryItem], next: UUID?) {
        self.id = id; self.path = path; self.parent = parent; self.items = items; self.next = next
    }
}

public struct FilePreview: Codable, Sendable, Equatable {
    public var name: String
    public var text: String
    public var truncated: Bool
    public var images: [OutputImageReference]?
    public init(name: String, text: String, truncated: Bool, images: [OutputImageReference]? = nil) {
        self.name = name; self.text = text; self.truncated = truncated; self.images = images
    }
}

public struct HistoryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var parent: String?
    public var kind: String
    public var text: String
    public var canFork: Bool
    public var preview: UUID?
    public init(id: String, parent: String?, kind: String, text: String, canFork: Bool, preview: UUID? = nil) {
        self.id = id; self.parent = parent; self.kind = kind; self.text = text; self.canFork = canFork; self.preview = preview
    }
}

public struct HistoryPage: Codable, Sendable, Equatable {
    public var items: [HistoryItem]
    public var next: UUID?
    public init(items: [HistoryItem], next: UUID?) { self.items = items; self.next = next }
}
