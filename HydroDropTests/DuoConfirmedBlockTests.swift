#if DUO_V2
import XCTest
@testable import HydroDrop

@MainActor
final class DuoConfirmedBlockTests: XCTestCase {
    private func makeKit() -> DuoTestKit {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        kit.transport.onBlock = { _, _ in }
        kit.dependencies.ops = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.store.upsert(DuoFixtures.duo())
        return kit
    }

    func testAConfirmedBlockSurvivesRelaunchAndClearRemovesItsRecord() async throws {
        let kit = makeKit()
        let duo = try XCTUnwrap(kit.store.duos.first)
        await kit.store.block(duo)
        XCTAssertTrue(kit.store.blockedDuoIDs.contains(duo.id))
        XCTAssertNil(kit.store.notice)
        XCTAssertTrue(DuoStore(cache: kit.store.cache).blockedDuoIDs.contains(duo.id))
        kit.store.clear(try XCTUnwrap(kit.store.duo(duo.id)))
        XCTAssertFalse(kit.store.blockedDuoIDs.contains(duo.id))
        XCTAssertFalse(kit.store.cache.loadBlockedDuoIDs().contains(duo.id))
    }

    func testDroppedBlocksSayTheyFailedAndAreNeverRememberedAsDone() async throws {
        let failures: [DuoTransportError] = [
            .unauthenticated(.init(httpStatus: 401)), .deviceRevoked(.init(httpStatus: 401)), .duoUnknown(.init(httpStatus: 404)),
            .duoEnded(.init(httpStatus: 409)), .termsRequired(.init(httpStatus: 428)),
            .unreadable(httpStatus: 204, requestID: nil), .unreadable(httpStatus: 451, requestID: nil), .schema(.init(httpStatus: 400))
        ]
        for error in failures {
            let kit = makeKit()
            let duo = try XCTUnwrap(kit.store.duos.first)
            kit.transport.onBlock = { _, _ in throw error }
            await kit.store.block(duo)
            XCTAssertTrue(try XCTUnwrap(kit.dependencies.ops).pending.isEmpty, "\(error)")
            XCTAssertNotNil(kit.store.notice, "\(error)")
            XCTAssertTrue(kit.store.blockedDuoIDs.isEmpty, "\(error)")
            XCTAssertTrue(kit.store.cache.loadBlockedDuoIDs().isEmpty, "\(error)")
        }
    }

    func testRelaunchPrunesBlockRecordsForCardsAlreadyGoneFromDisk() {
        let kit = makeKit()
        let orphan = UUID()
        kit.store.cache.saveBlockedDuoIDs([orphan])
        let relaunched = DuoStore(cache: kit.store.cache)
        XCTAssertTrue(relaunched.blockedDuoIDs.isEmpty)
        XCTAssertTrue(kit.store.cache.loadBlockedDuoIDs().isEmpty)
    }

    func testAWipeForgetsConfirmedBlocks() async throws {
        let kit = makeKit()
        await kit.store.block(try XCTUnwrap(kit.store.duos.first))
        XCTAssertFalse(kit.store.blockedDuoIDs.isEmpty)
        kit.store.resetLocalState()
        XCTAssertTrue(kit.store.blockedDuoIDs.isEmpty)
        XCTAssertNil(kit.store.cache.defaults.object(forKey: DuoCache.blockedKey))
    }
}
#endif
