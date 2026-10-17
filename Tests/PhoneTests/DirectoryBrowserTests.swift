import PiRemoteCore
import XCTest
@testable import PiRemote

@MainActor
final class DirectoryBrowserTests: XCTestCase {
    @MainActor private final class PendingRequest {
        var continuation: CheckedContinuation<AppResult, any Error>?
        func call(_ action: SessionAction) async throws -> AppResult {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func wait() async throws {
            for _ in 0..<1_000 {
                if continuation != nil { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("The browser did not issue its request")
            throw RemoteFault.unavailable
        }
        func finish(_ result: Result<AppResult, any Error>) {
            continuation?.resume(with: result); continuation = nil
        }
    }

    private func page(_ id: UUID = UUID(), index: Int = 0, next: UUID? = nil) -> DirectoryPage {
        DirectoryPage(id: id, path: "/fixture", parent: nil,
                      items: (0..<100).map { DirectoryItem(id: UUID(), name: "\(index)-\($0)", isDirectory: true) }, next: next)
    }

    func testPagesStayBoundedAndCachedForwardNavigationDoesNotConsumeCursorAgain() async {
        let browser = DirectoryBrowserModel(), id = UUID()
        var calls = 0
        let request: (SessionAction) async throws -> AppResult = { _ in
            defer { calls += 1 }
            return .directories(self.page(id, index: calls, next: UUID()))
        }
        await browser.open(id, request: request)
        for _ in 0..<12 { await browser.next(request: request) }
        XCTAssertEqual(calls, 13)
        XCTAssertEqual(browser.page?.items.count, 100)
        XCTAssertEqual(browser.previousPages.count, 8)
        XCTAssertEqual(browser.page?.items.first?.name, "12-0")
        for _ in 0..<8 { browser.previous() }
        XCTAssertEqual(browser.page?.items.first?.name, "4-0")
        browser.previous()
        XCTAssertEqual(browser.page?.items.first?.name, "4-0")
        for _ in 0..<8 { await browser.next(request: request) }
        XCTAssertEqual(calls, 13)
        XCTAssertEqual(browser.page?.items.first?.name, "12-0")
        await browser.next(request: request)
        XCTAssertEqual(calls, 14)
        XCTAssertEqual(browser.page?.items.first?.name, "13-0")
        await browser.open(UUID(), request: request)
        XCTAssertTrue(browser.previousPages.isEmpty)
    }

    func testOldFailureCannotClearNewLoadingStateOrSetItsError() async throws {
        let browser = DirectoryBrowserModel(), old = PendingRequest(), current = PendingRequest()
        let first = Task { await browser.open(UUID(), request: old.call) }
        try await old.wait()
        let second = Task { await browser.open(UUID(), request: current.call) }
        try await current.wait()
        old.finish(.failure(RemoteFault.permissionDenied)); await first.value
        XCTAssertTrue(browser.loading)
        XCTAssertNil(browser.fault)
        XCTAssertNil(browser.page)
        let expected = page()
        current.finish(.success(.directories(expected))); await second.value
        XCTAssertFalse(browser.loading)
        XCTAssertEqual(browser.page, expected)
    }

    func testOldSuccessCannotReplaceNewDirectory() async throws {
        let browser = DirectoryBrowserModel(), old = PendingRequest()
        let first = Task { await browser.open(UUID(), request: old.call) }
        try await old.wait()
        let expected = page()
        await browser.open(expected.id) { _ in .directories(expected) }
        old.finish(.success(.directories(page()))); await first.value
        XCTAssertEqual(browser.page, expected)
        XCTAssertFalse(browser.loading)
    }

    func testCancelledLoadDoesNotExposeReturnedDirectoryOrError() async throws {
        let browser = DirectoryBrowserModel(), pending = PendingRequest()
        let task = Task { await browser.open(UUID(), request: pending.call) }
        try await pending.wait(); task.cancel()
        pending.finish(.success(.directories(page()))); await task.value
        XCTAssertNil(browser.page)
        XCTAssertNil(browser.fault)
        XCTAssertFalse(browser.loading)
    }

    func testPreviewCannotAppearAfterDirectoryChange() async throws {
        let browser = DirectoryBrowserModel(), pending = PendingRequest()
        let first = page()
        await browser.open(first.id) { _ in .directories(first) }
        let preview = Task { await browser.openPreview(UUID(), request: pending.call) }
        try await pending.wait()
        let second = page()
        await browser.open(second.id) { _ in .directories(second) }
        pending.finish(.success(.preview(FilePreview(name: "old", text: "Private fixture", truncated: false))))
        await preview.value
        XCTAssertNil(browser.preview)
        XCTAssertEqual(browser.page, second)
        XCTAssertFalse(browser.loading)
    }

    func testFailedNavigationCannotStartInPreviousFolderAndRetryUsesNewFolder() async {
        let browser = DirectoryBrowserModel(), first = page(), next = UUID()
        await browser.open(first.id) { _ in .directories(first) }
        await browser.open(next) { _ in throw RemoteFault.permissionDenied }
        XCTAssertNil(browser.page)
        XCTAssertEqual(browser.fault, .permissionDenied)
        await browser.retry { action in
            XCTAssertEqual(action, .directories(id: next, cursor: nil))
            return .directories(self.page(next))
        }
        XCTAssertEqual(browser.page?.id, next)
        XCTAssertNil(browser.fault)
    }

    func testTypedPathClearsOldSelectionAndRetriesTheExactPath() async {
        let browser = DirectoryBrowserModel(), first = page(), path = "~/project with spaces"
        await browser.open(first.id) { _ in .directories(first) }
        await browser.open(path: path) { action in
            XCTAssertEqual(action, .directoryAtPath(path: path))
            throw RemoteFault.permissionDenied
        }
        XCTAssertNil(browser.page)
        XCTAssertTrue(browser.previousPages.isEmpty)
        XCTAssertEqual(browser.fault, .permissionDenied)
        let expected = page()
        await browser.retry { action in
            XCTAssertEqual(action, .directoryAtPath(path: path))
            return .directories(expected)
        }
        XCTAssertEqual(browser.page, expected)
        await browser.open(expected.id) { action in
            XCTAssertEqual(action, .directories(id: expected.id, cursor: nil))
            return .directories(expected)
        }
    }

    func testOldTypedPathReplyCannotReplaceNewNavigation() async throws {
        let browser = DirectoryBrowserModel(), pending = PendingRequest(), expected = page()
        let old = Task { await browser.open(path: "/old", request: pending.call) }
        try await pending.wait()
        await browser.open(path: "/new") { action in
            XCTAssertEqual(action, .directoryAtPath(path: "/new"))
            return .directories(expected)
        }
        pending.finish(.success(.directories(page()))); await old.value
        XCTAssertEqual(browser.page, expected)
        XCTAssertNil(browser.fault)
        XCTAssertFalse(browser.loading)
    }

    func testCancelledTypedPathReplyCannotEnableSelection() async throws {
        let browser = DirectoryBrowserModel(), pending = PendingRequest()
        let task = Task { await browser.open(path: "/cancelled", request: pending.call) }
        try await pending.wait(); task.cancel()
        pending.finish(.success(.directories(page()))); await task.value
        XCTAssertNil(browser.page)
        XCTAssertFalse(browser.loading)
        XCTAssertNil(browser.fault)
    }
}
