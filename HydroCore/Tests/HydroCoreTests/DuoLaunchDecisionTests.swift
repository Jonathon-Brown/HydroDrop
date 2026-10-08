import XCTest
@testable import HydroCore

/// The pure rules of final design §3.4: which launch this is, and when to ask "This phone was
/// connected to a duo with <partner>. Continue as <name>?".
final class DuoLaunchDecisionTests: XCTestCase {
    private let ownerDuo = "6d2a0000-0000-4000-8000-000000000001"
    private let partnerDuo = "6d2a0000-0000-4000-8000-000000000002"
    private let thirdDuo = "6d2a0000-0000-4000-8000-000000000003"

    private func header(_ id: String, role: DuoRole, owner: String?, partner: String?, state: DuoWireDuoState = .active) -> DuoWireHeader {
        DuoWireHeader(id: id, myRole: role, state: state, createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                      ownerDisplayName: owner, ownerSkin: "classic", partnerDisplayName: partner, partnerSkin: "forest", seq: 3)
    }

    private func me(name: String?, duos: [DuoWireHeader]) -> DuoWireGetMeResponse {
        DuoWireGetMeResponse(
            member: DuoWireMember(id: "6d2a0000-0000-4000-8000-0000000000aa", displayName: name, supportId: "ABCD1234EFGH", tier: .low, termsVersion: 1),
            limits: DuoWireLimits(nudgesPerDay: 1, maxActiveDuos: 1),
            devices: [], duos: duos, minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
    }

    // MARK: - decide

    func testNoCredentialIsNoIdentityWhateverElseIsThere() {
        for marker in [false, true] {
            for settled in [false, true] {
                XCTAssertEqual(DuoLaunchDecision.decide(hasCredential: false, hasMarker: marker, isSettled: settled), DuoLaunchDecision.Launch.none,
                               "a marker or a settled file left by a discarded identity has nothing to launch")
            }
        }
    }

    func testACredentialItsMarkerAndASettledInstallIsAnOrdinaryLaunch() {
        XCTAssertEqual(DuoLaunchDecision.decide(hasCredential: true, hasMarker: true, isSettled: true), .normal)
    }

    func testACredentialWithoutItsMarkerCameFromAnotherPhoneWhateverTheSettledFileSays() {
        XCTAssertEqual(DuoLaunchDecision.decide(hasCredential: true, hasMarker: false, isSettled: false), .restored)
        XCTAssertEqual(DuoLaunchDecision.decide(hasCredential: true, hasMarker: false, isSettled: true), .restored,
                       "a settled file without the marker is not this phone's to trust")
    }

    func testACredentialAndItsMarkerOnAnInstallThatNeverSettledIsAskedAboutNotRotated() {
        XCTAssertEqual(DuoLaunchDecision.decide(hasCredential: true, hasMarker: true, isSettled: false), .unsettled,
                       "a same-phone reinstall, or a restore interrupted after its rotate")
    }

    // MARK: - restorePrompt

    func testThePromptIsAskedOnlyWhenTheServerListsADuoAndThisPhoneHoldsNone() {
        let listed = me(name: "Jo", duos: [header(ownerDuo, role: .owner, owner: "Jo", partner: "Sam")])
        XCTAssertNotNil(DuoLaunchDecision.restorePrompt(from: listed, cachedDuoCount: 0))
        XCTAssertNil(DuoLaunchDecision.restorePrompt(from: listed, cachedDuoCount: 1),
                     "a phone that already holds duos keeps them: there is nothing to ask")
        XCTAssertNil(DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: []), cachedDuoCount: 0),
                     "no duo listed: the restore settles without a question")
    }

    func testAnOwnerIsAskedAboutThePartnerAndAPartnerAboutTheOwner() {
        let asOwner = DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: [header(ownerDuo, role: .owner, owner: "Jo", partner: "Sam")]),
                                                      cachedDuoCount: 0)
        XCTAssertEqual(asOwner, DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let asPartner = DuoLaunchDecision.restorePrompt(from: me(name: "Sam", duos: [header(partnerDuo, role: .partner, owner: "Jo", partner: "Sam")]),
                                                        cachedDuoCount: 0)
        XCTAssertEqual(asPartner, DuoRestorePrompt(partnerName: "Jo", myName: "Sam"))
    }

    func testThePartnerIsNamedFromAnActiveDuoFirstThenAPendingOneThenAnyOther() {
        let ended = DuoWireHeader(id: ownerDuo, myRole: .partner, state: .ended, endedAt: Date(timeIntervalSince1970: 1_789_500_000),
                                  endedBy: .partner, seq: 9)
        let pending = header(partnerDuo, role: .owner, owner: "Jo", partner: nil, state: .pending)
        let active = header(thirdDuo, role: .partner, owner: "Alex", partner: "Jo")

        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: [ended, pending, active]), cachedDuoCount: 0)?.partnerName,
                       "Alex", "an active duo, wherever it is listed")
        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: [ended, pending]), cachedDuoCount: 0),
                       DuoRestorePrompt(partnerName: nil, myName: "Jo"), "else one waiting for its partner, who has no name yet")
        var namedPending = pending
        namedPending.partnerDisplayName = "Sam"
        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: [ended, namedPending]), cachedDuoCount: 0)?.partnerName, "Sam")
        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: me(name: "Sam", duos: [ended]), cachedDuoCount: 0),
                       DuoRestorePrompt(partnerName: nil, myName: "Sam"), "else an ended one the server still lists, names masked")
    }

    func testTheFirstOfSeveralActiveDuosNamesThePartner() {
        let both = me(name: "Jo", duos: [header(ownerDuo, role: .owner, owner: "Jo", partner: "Sam"),
                                         header(partnerDuo, role: .partner, owner: "Alex", partner: "Jo")])
        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: both, cachedDuoCount: 0)?.partnerName, "Sam")
    }

    func testEitherNameMayBeMissing() {
        let unnamed = DuoLaunchDecision.restorePrompt(from: me(name: nil, duos: [header(ownerDuo, role: .owner, owner: nil, partner: nil)]),
                                                      cachedDuoCount: 0)
        XCTAssertEqual(unnamed, DuoRestorePrompt(partnerName: nil, myName: nil))
    }

    func testADuoWhoseIdIsNotAUUIDIsNotOneToAskAbout() {
        let broken = header("not-a-uuid", role: .owner, owner: "Jo", partner: "Mallory")
        XCTAssertNil(DuoLaunchDecision.restorePrompt(from: me(name: "Jo", duos: [broken]), cachedDuoCount: 0),
                     "Continue could seed nothing from it")
        let mixed = me(name: "Jo", duos: [broken, header(ownerDuo, role: .owner, owner: "Jo", partner: "Sam", state: .ended)])
        XCTAssertEqual(DuoLaunchDecision.restorePrompt(from: mixed, cachedDuoCount: 0)?.partnerName, "Sam",
                       "an active duo with a broken id is not preferred over one this build can hold")
    }
}
