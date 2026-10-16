import Foundation
import LocalAuthentication
import PiRemoteCore
import SwiftUI
import XCTest
@testable import PiRemote

@MainActor
private final class PendingUnlock {
    private var pending: [CheckedContinuation<Bool, any Error>?] = []
    var count: Int { pending.count }
    func evaluate(_ context: LAContext) async throws -> Bool {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int, approved: Bool) {
        guard pending.indices.contains(index), let continuation = pending[index] else { return }
        pending[index] = nil
        continuation.resume(returning: approved)
    }
    func cancel() { for index in pending.indices { finish(index, approved: false) } }
}

@MainActor
final class AuthenticationTests: XCTestCase {
    private func settled(_ model: PhoneModel) async throws {
        for _ in 0..<100 where model.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.unlocking)
    }

    func testDeniedOrFailedAuthenticationKeepsRemoteContentUnavailable() async throws {
        for throwsError in [false, true] {
            let name = "PiRemoteUnlockTests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let model = PhoneModel(defaults: defaults, authenticate: { _ in
                if throwsError { throw LAError(.authenticationFailed) }
                return false
            })
            let host = UUID(); model.chooseMac(host)
            model.scene(.active)
            try await settled(model)
            XCTAssertTrue(model.locked)
            XCTAssertNotNil(model.authError)
            model.applyState(HostSnapshot(host: host, epoch: UUID()))
            XCTAssertNil(model.state)
            XCTAssertFalse(model.connected || model.connecting)
            do { _ = try await model.request(.directories(id: nil, cursor: nil)); XCTFail("Locked browsing must fail") }
            catch { XCTAssertEqual(error as? RemoteFault, .unavailable) }
            model.send()
            XCTAssertFalse(model.sending)
            model.lock()
        }
    }

    func testBackgroundReturnRequiresAnotherAuthenticationAndCannotRevealCachedState() async throws {
        let name = "PiRemoteUnlockTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var attempts = 0
        let model = PhoneModel(defaults: defaults, authenticate: { _ in attempts += 1; return attempts != 2 })
        let host = UUID(); model.chooseMac(host)
        model.scene(.active); try await settled(model)
        XCTAssertFalse(model.locked || model.covered)
        model.applyState(HostSnapshot(host: host, epoch: UUID()))
        XCTAssertNotNil(model.state)
        model.scene(.inactive)
        XCTAssertTrue(model.covered)
        model.scene(.active)
        XCTAssertEqual(attempts, 1)
        model.scene(.background)
        XCTAssertTrue(model.locked && model.covered)
        XCTAssertNil(model.state)
        model.scene(.active); try await settled(model)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(model.locked)
        XCTAssertNil(model.state)
        model.unlock(); try await settled(model)
        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(model.locked)
        XCTAssertNil(model.state)
        model.lock()
    }

    func testLateSuccessFromBeforeSimulatedLockCannotUnlockOrFinishANewerAttempt() async throws {
        let name = "PiRemoteUnlockTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let pending = PendingUnlock()
        let model = PhoneModel(defaults: defaults, authenticate: pending.evaluate)
        defer { model.lock(); pending.cancel() }
        model.scene(.active)
        for _ in 0..<100 where pending.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(pending.count, 1)
        model.scene(.background)
        model.scene(.active)
        for _ in 0..<100 where pending.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(pending.count, 2)
        pending.finish(0, approved: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.locked && model.unlocking)
        XCTAssertNil(model.state)
        pending.finish(1, approved: false)
        try await settled(model)
        XCTAssertTrue(model.locked)
        XCTAssertNotNil(model.authError)
        XCTAssertNil(model.state)
        model.lock()
    }
}
