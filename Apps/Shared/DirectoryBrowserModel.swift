import Foundation
import Observation
import PiRemoteCore

@MainActor @Observable
final class DirectoryBrowserModel {
    private(set) var page: DirectoryPage?
    private(set) var loading = false
    private(set) var fault: RemoteFault?
    var preview: FilePreview?
    private(set) var previousPages: [DirectoryPage] = []
    // Directory cursors advance on each host read. Reuse cached pages when moving forward again.
    private var followingPages: [DirectoryPage] = []
    private var directory: UUID?
    private var pendingPath: String?
    private var generation = UUID()

    func open(_ id: UUID?, request: (SessionAction) async throws -> AppResult) async {
        directory = id; pendingPath = nil
        page = nil; previousPages = []; followingPages = []; preview = nil
        await load(cursor: nil, request: request)
    }

    func open(path: String, request: (SessionAction) async throws -> AppResult) async {
        directory = nil; pendingPath = path
        page = nil; previousPages = []; followingPages = []; preview = nil
        await load(cursor: nil, path: path, request: request)
    }

    func retry(request: (SessionAction) async throws -> AppResult) async {
        if let pendingPath { await open(path: pendingPath, request: request) }
        else { await open(directory, request: request) }
    }

    func next(request: (SessionAction) async throws -> AppResult) async {
        guard !loading else { return }
        if let value = followingPages.popLast() {
            if let page { previousPages.append(page) }
            page = value; fault = nil; preview = nil
            return
        }
        guard let cursor = page?.next else { return }
        await load(cursor: cursor, request: request)
    }

    func previous() {
        guard !loading, let value = previousPages.popLast() else { return }
        if let page { followingPages.append(page) }
        generation = UUID(); page = value; fault = nil; preview = nil
    }

    private func load(cursor: UUID?, path: String? = nil, request: (SessionAction) async throws -> AppResult) async {
        let token = UUID()
        generation = token; loading = true; fault = nil
        defer { if generation == token { loading = false } }
        do {
            let result = try await request(path.map { .directoryAtPath(path: $0) } ?? .directories(id: directory, cursor: cursor))
            guard generation == token, !Task.isCancelled else { return }
            guard case .directories(let value) = result else { throw RemoteFault.invalidRequest }
            if cursor != nil {
                guard value.id == page?.id else { throw RemoteFault.conflict }
                if let page { previousPages.append(page); previousPages = Array(previousPages.suffix(8)) }
            }
            directory = value.id; pendingPath = nil; page = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            fault = error as? RemoteFault ?? .unavailable
        }
    }

    func openPreview(_ id: UUID, request: (SessionAction) async throws -> AppResult) async {
        guard !loading else { return }
        let token = UUID()
        generation = token; loading = true; fault = nil
        defer { if generation == token { loading = false } }
        do {
            let result = try await request(.preview(id: id))
            guard generation == token, !Task.isCancelled else { return }
            guard case .preview(let value) = result else { throw RemoteFault.invalidRequest }
            preview = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            fault = error as? RemoteFault ?? .unavailable
        }
    }
}
