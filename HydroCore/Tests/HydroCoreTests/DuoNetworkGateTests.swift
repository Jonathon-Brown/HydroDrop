import XCTest
@testable import HydroCore

private actor GateLatch {
    private var began = false
    private var release: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        began = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilBegan() async {
        if began { return }
        await withCheckedContinuation { observer = $0 }
    }
    func open() { release?.resume(); release = nil }
}

final class DuoNetworkGateTests: XCTestCase {
    func testKnownRefusalCannotBeLifted() {
        let gate = DuoNetworkGate()
        gate.transition(to: .refused)
        XCTAssertFalse(gate.transition(to: .open))
        XCTAssertEqual(gate.state, .refused)
        XCTAssertFalse(gate.transition(to: .unavailable))
    }

    func testUnavailableBlocksWithoutPermanentlyRefusing() async throws {
        let gate = DuoNetworkGate()
        do {
            _ = try await gate.run { XCTFail("blocked work ran"); return 1 }
            XCTFail("must throw")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        gate.transition(to: .open)
        let result = try await gate.run { 7 }
        XCTAssertEqual(result, 7)
    }

    func testDeletionIsAllowedAfterRefusal() async throws {
        let gate = DuoNetworkGate()
        gate.transition(to: .refused)
        let result = try await gate.run(deletion: true) { 7 }
        XCTAssertEqual(result, 7)
    }

    func testLateOrdinaryAnswerIsInvalidatedEvenIfOperationIgnoresCancellation() async {
        let gate = DuoNetworkGate()
        gate.transition(to: .open)
        let latch = GateLatch()
        let work = Task { try await gate.run { await latch.wait(); return 7 } }
        await latch.waitUntilBegan()
        gate.transition(to: .refused)
        await latch.open()
        do { _ = try await work.value; XCTFail("late answer escaped") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    func testTemporaryFailureAndRecoveryDoNotReviveAnOldAnswer() async {
        let gate = DuoNetworkGate()
        gate.transition(to: .open)
        let latch = GateLatch()
        let work = Task { try await gate.run { await latch.wait(); return 7 } }
        await latch.waitUntilBegan()
        gate.transition(to: .unavailable)
        gate.transition(to: .open)
        await latch.open()
        do { _ = try await work.value; XCTFail("old generation escaped") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    func testRefusalDoesNotCancelDeletionAlreadyInFlight() async throws {
        let gate = DuoNetworkGate()
        gate.transition(to: .open)
        let latch = GateLatch()
        let work = Task { try await gate.run(deletion: true) { await latch.wait(); try Task.checkCancellation(); return 7 } }
        await latch.waitUntilBegan()
        gate.transition(to: .refused)
        await latch.open()
        let answer = try await work.value
        XCTAssertEqual(answer, 7)
    }
}

extension DuoNetworkGateTests {
    func testDispatchedRotationCanReturnItsOnlyCredentialButNewRotationCannotStart() async throws {
        let gate = DuoNetworkGate()
        gate.transition(to: .open)
        let latch = GateLatch()
        let work = Task {
            try await gate.run(preservingDispatchedAnswer: true) { await latch.wait(); return "new secret" }
        }
        await latch.waitUntilBegan()
        gate.transition(to: .refused)
        await latch.open()
        let result = try await work.value
        XCTAssertEqual(result, "new secret")
        do {
            _ = try await gate.run(preservingDispatchedAnswer: true) { XCTFail("new rotate ran"); return "wrong" }
            XCTFail("new rotate was allowed")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }
}
