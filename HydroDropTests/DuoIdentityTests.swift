#if DUO_V2
import XCTest
@testable import HydroDrop

// MARK: - Test helpers (stage B)

/// Holds a request until the test lets it go, so a test can act while it is out (a wipe, a
/// "Start fresh", two more callers).
fileprivate final class BGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// `FakeDuoTransport` with a gate in front of the rotate and the `GET /me`.
fileprivate final class BGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var rotateGate: BGate?
    var meGate: BGate?

    init(_ base: FakeDuoTransport) { self.base = base }

    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse {
        if let rotateGate { await rotateGate.wait() }
        return try await base.rotate(as: credential)
    }

    func me() async throws -> DuoWireGetMeResponse {
        if let meGate { await meGate.wait() }
        return try await base.me()
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await base.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await base.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await base.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// A memory store that records every write (with its accessibility) and every delete, and can
/// be made to fail reads, as the Keychain does before the first unlock after a restart, or
/// writes: of every account, or of chosen ones.
fileprivate final class BRecordingSecretStore: DuoSecretStore, @unchecked Sendable {
    let memory: DuoMemorySecretStore
    private let lock = NSLock()
    private var written: [(item: String, accessibility: DuoSecretAccessibility)] = []
    private var deleted: [String] = []
    private var unreadable = false
    private var unwritable = false
    private var unreadableAccounts: Set<String> = []
    private var unwritableAccounts: Set<String> = []
    private var undeletable = false

    init(memory: DuoMemorySecretStore = DuoMemorySecretStore()) { self.memory = memory }

    func refuseReads(of accounts: Set<String>) { lock.lock(); unreadableAccounts = accounts; lock.unlock() }
    func refuseWrites(to accounts: Set<String>) { lock.lock(); unwritableAccounts = accounts; lock.unlock() }
    func clearLog() { lock.lock(); written = []; deleted = []; lock.unlock() }

    var writes: [(item: String, accessibility: DuoSecretAccessibility)] { lock.lock(); defer { lock.unlock() }; return written }
    var deletes: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
    var locked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return unreadable }
        set { lock.lock(); unreadable = newValue; lock.unlock() }
    }
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return unwritable }
        set { lock.lock(); unwritable = newValue; lock.unlock() }
    }
    var failDeletes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return undeletable }
        set { lock.lock(); undeletable = newValue; lock.unlock() }
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock(); let refused = unreadable || unreadableAccounts.contains(account); lock.unlock()
        if refused { throw DuoKeychainError(status: errSecInteractionNotAllowed) }
        return try memory.read(service: service, account: account)
    }

    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        lock.lock(); let refused = unwritable || unwritableAccounts.contains(account); lock.unlock()
        if refused { throw DuoKeychainError(status: errSecNotAvailable) }
        lock.lock(); written.append(("\(service)/\(account)", accessibility)); lock.unlock()
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }

    func delete(service: String, account: String) throws {
        if failDeletes { throw DuoKeychainError(status: errSecInteractionNotAllowed) }
        lock.lock(); deleted.append("\(service)/\(account)"); lock.unlock()
        try memory.delete(service: service, account: account)
    }

    func deleteAll(service: String) throws {
        if failDeletes { throw DuoKeychainError(status: errSecInteractionNotAllowed) }
        lock.lock(); deleted.append("\(service)/*"); lock.unlock()
        try memory.deleteAll(service: service)
    }
}

/// Counts the times the identity asked to keep running in the background, and whether it still is.
fileprivate final class BHoldRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return begun > ended }
    var holds: Int { lock.lock(); defer { lock.unlock() }; return begun }

    var hold: DuoIdentity.BackgroundHold {
        { [self] _ in
            lock.lock(); begun += 1; lock.unlock()
            return { [self] in lock.lock(); ended += 1; lock.unlock() }
        }
    }
}

/// The server's device table as contract-v1 judges a bearer: an unknown device is 401
/// `unauthenticated`, a wrong secret 401 `device_revoked`, and a rotate overwrites the secret.
fileprivate final class BServer: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: (secret: String, version: Int)] = [:]
    private var minted = 0
    private var rotationCount = 0

    var rotations: Int { lock.lock(); defer { lock.unlock() }; return rotationCount }

    func enroll(_ credential: DuoCredential) {
        lock.lock(); rows[credential.deviceID] = (credential.deviceSecret, credential.secretVersion); lock.unlock()
    }

    func authenticate(_ credential: DuoCredential?) throws {
        lock.lock(); defer { lock.unlock() }
        guard let credential, let row = rows[credential.deviceID] else {
            throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 401, requestID: "r"))
        }
        guard row.secret == credential.deviceSecret else { throw DuoTransportError.deviceRevoked(DuoErrorContext(httpStatus: 401, requestID: "r")) }
    }

    func rotate(_ credential: DuoCredential?) throws -> DuoWireRotateResponse {
        try authenticate(credential)
        lock.lock(); defer { lock.unlock() }
        minted += 1
        rotationCount += 1
        let secret = String(format: "%043d", minted)
        let version = (rows[credential!.deviceID]?.version ?? 0) + 1
        rows[credential!.deviceID] = (secret, version)
        return DuoWireRotateResponse(deviceSecret: secret, secretVersion: version)
    }
}

/// A phone's transport against `BServer`, as the API client sends: the rotate as the credential
/// it is handed, every other bearer call as whatever the identity holds when the call runs.
/// `beforeSend` stands for the hop between the launch's call and the request leaving.
fileprivate final class BServerTransport: DuoTransport, @unchecked Sendable {
    let server: BServer
    let base = FakeDuoTransport()
    weak var identity: DuoIdentity?
    var beforeSend: BGate?
    let meAnswer: @Sendable () -> DuoWireGetMeResponse
    private let lock = NSLock()
    private var rotated: [DuoCredential] = []
    var rotatedAs: [DuoCredential] { lock.lock(); defer { lock.unlock() }; return rotated }

    init(server: BServer, meAnswer: @escaping @Sendable () -> DuoWireGetMeResponse) {
        self.server = server
        self.meAnswer = meAnswer
    }

    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse {
        if let beforeSend { await beforeSend.wait() }
        lock.withLock { rotated.append(credential) }
        return try server.rotate(credential)
    }
    func me() async throws -> DuoWireGetMeResponse {
        try server.authenticate(identity?.credential)
        return meAnswer()
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await base.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await base.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await base.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// A clock whose next reading runs a one-shot action first: a deterministic hook into the few
/// places the identity reads the time (Continue, right after it takes the answer; a launch, right
/// after its `GET /me` was accepted).
fileprivate final class BHookClock: DuoClock, @unchecked Sendable {
    private let base = TestClock()
    private let lock = NSLock()
    private var action: (() -> Void)?

    func arm(_ action: @escaping () -> Void) { lock.lock(); self.action = action; lock.unlock() }

    var now: Date {
        lock.lock(); let once = action; action = nil; lock.unlock()
        once?()
        return base.now
    }

    var calendar: Calendar { base.calendar }
}

/// The identity under test, over a `DuoTestKit` whose other services stay fakes.
@MainActor
fileprivate struct BRig {
    let kit: DuoTestKit
    let identity: DuoIdentity
    let gated: BGatedTransport
    let directory: URL
    let holds: BHoldRecorder
    let deviceCheck: DuoReviewCountingDeviceCheck

    var transport: FakeDuoTransport { kit.transport }
    var secrets: DuoSecrets { kit.dependencies.secrets }
    var installFile: URL { directory.appendingPathComponent("duo.install") }
    var settledFile: URL { directory.appendingPathComponent("duo.settled") }
    var isSettled: Bool { FileManager.default.fileExists(atPath: settledFile.path) }

    init(kit: DuoTestKit, directory: URL, excludeFromBackup: @escaping DuoIdentity.BackupExclusion = DuoIdentity.markExcludedFromBackup) {
        self.kit = kit
        self.directory = directory
        holds = BHoldRecorder()
        deviceCheck = DuoReviewCountingDeviceCheck()
        kit.dependencies.deviceCheck = deviceCheck
        gated = BGatedTransport(kit.transport)
        kit.dependencies.transport = gated
        identity = DuoIdentity(dependencies: kit.dependencies, directory: directory, holdInBackground: holds.hold,
                               excludeFromBackup: excludeFromBackup)
        kit.dependencies.identity = identity
    }

    /// Nothing in the identity attests, asserts or asks DeviceCheck, whatever the launch.
    func assertNothingAttestedOrChecked(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(kit.attester.attestedNewKeys, 0, "no attestation", file: file, line: line)
        XCTAssertTrue(kit.attester.assertions.isEmpty, "no assertion", file: file, line: line)
        XCTAssertEqual(deviceCheck.calls, 0, "no DeviceCheck token", file: file, line: line)
    }

    nonisolated static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DuoIdentityTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A phone that holds a credential, with or without this phone's marker, on an install that
    /// did or did not settle.
    func holdCredential(marker: Bool, settled: Bool = false) throws {
        try secrets.save(DuoFixtures.credential())
        if marker { try secrets.writeInstallMarker(random: kit.random) }
        if settled { try markSettled() }
    }

    func markSettled() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: settledFile)
    }
}

@MainActor
final class DuoIdentityTests: XCTestCase {
    private let newSecret = String(repeating: "n", count: 43)
    private let otherDuoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
    private var folders: [URL] = []
    /// What a test's identities depend on and nothing else holds: `DuoDependencies` keeps its
    /// host unowned, so a kit made in a helper would be freed under the identity it serves.
    private var keptAlive: [AnyObject] = []

    override func tearDown() {
        for folder in folders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        folders = []
        keptAlive = []
        super.tearDown()
    }

    private func rig(kit: DuoTestKit? = nil, directory: URL? = nil,
                     excludeFromBackup: @escaping DuoIdentity.BackupExclusion = DuoIdentity.markExcludedFromBackup) -> BRig {
        let folder = directory ?? BRig.temporaryDirectory()
        folders.append(folder)
        return BRig(kit: kit ?? DuoTestKit(), directory: folder, excludeFromBackup: excludeFromBackup)
    }

    /// An identity over `secretStore` instead of the kit's, for a test that has to watch or fail
    /// the Keychain itself.
    private func identity(over secretStore: DuoSecretStore, kit: DuoTestKit, directory: URL? = nil) -> (DuoIdentity, DuoDependencies, URL) {
        let folder = directory ?? BRig.temporaryDirectory()
        folders.append(folder)
        let dependencies = DuoDependencies(host: kit.store, cache: kit.dependencies.cache, secrets: DuoSecrets(store: secretStore),
                                           clock: kit.clock, random: kit.random, client: kit.dependencies.client,
                                           attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        dependencies.transport = kit.transport
        dependencies.ops = kit.ops
        let identity = DuoIdentity(dependencies: dependencies, directory: folder, holdInBackground: BHoldRecorder().hold)
        dependencies.identity = identity
        return (identity, dependencies, folder)
    }

    private func rotated(version: Int = 2) -> DuoWireRotateResponse {
        DuoWireRotateResponse(deviceSecret: newSecret, secretVersion: version)
    }

    private func me(name: String? = "Jo", duos: [DuoWireHeader]) -> DuoWireGetMeResponse {
        let credential = DuoFixtures.credential()
        return DuoWireGetMeResponse(
            member: DuoWireMember(id: credential.memberID, displayName: name, skin: "classic", supportId: "ABCD1234EFGH", tier: .low, termsVersion: 1),
            limits: DuoWireLimits(nudgesPerDay: 1, maxActiveDuos: 1),
            devices: [DuoWireDevice(id: credential.deviceID, platform: "ios", createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                                    thisDevice: true, superseded: false)],
            duos: duos, minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
    }

    private func failure(_ code: DuoErrorCode, status: Int) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "req-1"))
    }

    private func rotates(_ transport: FakeDuoTransport) -> Int { transport.calls.filter { $0 == .rotate }.count }

    private func isExcludedFromBackup(_ file: URL) throws -> Bool? {
        try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    /// Lets the main actor run until `condition` holds, or fails the test after a bounded wait.
    private func yield(until condition: () -> Bool, _ message: String) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - An ordinary launch

    func testNoCredentialIsNoIdentityAndNothingIsSentOrWritten() async {
        let rig = rig()
        let answer = await rig.identity.prepare()
        XCTAssertEqual(answer, DuoIdentityLaunch.none)
        XCTAssertTrue(rig.transport.calls.isEmpty, "§3.1: nothing is sent until a Create, Join or Reconnect tap")
        XCTAssertTrue(rig.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty, "no marker, no credential")
        XCTAssertEqual(rig.kit.attester.attestedNewKeys, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.directory.path), "a launch writes neither the install day nor the settled file")
        XCTAssertEqual(rig.kit.store.availability, .unknown)
        rig.assertNothingAttestedOrChecked()
    }

    func testACredentialItsMarkerAndASettledInstallIsReadyAndSendsNothing() async throws {
        let rig = rig()
        try rig.holdCredential(marker: true, settled: true)
        let answer = await rig.identity.prepare()
        XCTAssertEqual(answer, .ready)
        XCTAssertTrue(rig.transport.calls.isEmpty, "GET /me is the sync engine's business, not the launch's")
        XCTAssertEqual(rig.identity.credential, DuoFixtures.credential())
        for _ in 0..<50 { await Task.yield() }
        rig.assertNothingAttestedOrChecked()
    }

    /// The consent rule measured on every Keychain write and delete, under any service: a launch
    /// with no credential, and an ordinary one, only read.
    func testALaunchWithNoCredentialOrAnOrdinaryOneOnlyReadsTheKeychain() async throws {
        for hasCredential in [false, true] {
            let kit = DuoTestKit()
            let recording = BRecordingSecretStore()
            let (identity, dependencies, folder) = identity(over: recording, kit: kit)
            if hasCredential {
                try dependencies.secrets.save(DuoFixtures.credential())
                try dependencies.secrets.writeInstallMarker(random: kit.random)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: folder.appendingPathComponent("duo.settled"))
            }
            let seeded = recording.writes.count
            let answer = await identity.prepare()
            XCTAssertEqual(answer, hasCredential ? .ready : DuoIdentityLaunch.none)
            XCTAssertEqual(recording.writes.count, seeded, "a launch writes nothing to the Keychain")
            XCTAssertTrue(recording.deletes.isEmpty)
            XCTAssertTrue(kit.transport.calls.isEmpty)
        }
    }

    // MARK: - No credential, yet duos in the cache

    func testLiveDuosWithoutACredentialAreTheDisconnectedQuestion() async {
        let rig = rig()
        rig.kit.store.upsert(DuoFixtures.duo())

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, DuoIdentityLaunch.none, "no identity: nothing can be sent")
        XCTAssertEqual(rig.kit.store.availability, .disconnected, "an unencrypted backup brought the cache without the Keychain item")
        XCTAssertTrue(rig.kit.store.availability.allowsReconnect, "so \"I had a duo\" is offered, as is Start fresh")
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty)

        let endedOnly = self.rig()
        endedOnly.kit.store.upsert(DuoFixtures.duo(ended: true))
        _ = await endedOnly.identity.prepare()
        XCTAssertEqual(endedOnly.kit.store.availability, .unknown, "an ended card needs no identity: it can still be cleared")
    }

    func testAKeychainThatCannotBeReadYetIsNotAnAnswer() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(DuoFixtures.duo())
        let recording = BRecordingSecretStore()
        let (identity, dependencies, folder) = identity(over: recording, kit: kit)
        try dependencies.secrets.save(DuoFixtures.credential())
        try dependencies.secrets.writeInstallMarker(random: kit.random)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("duo.settled"))

        // Before the first unlock after a restart.
        recording.locked = true
        XCTAssertNil(identity.credential)
        let before = await identity.prepare()
        XCTAssertEqual(before, .unavailable, "unknown is not \"no identity\": a tap must not mint a second one beside it")
        XCTAssertEqual(kit.store.availability, .unknown, "nor is a phone whose Keychain is still locked a disconnected one")

        recording.locked = false
        XCTAssertEqual(identity.credential, DuoFixtures.credential(), "read again, not remembered as missing")
        let after = await identity.prepare()
        XCTAssertEqual(after, .ready)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    // MARK: - A restore onto another phone

    func testARestoreRotatesOnceSavesTheSecretAndTheMarkerThenReadsMe() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        try rig.markSettled() // a copy a backup should never have carried
        let secrets = rig.secrets
        let settledFile = rig.settledFile
        let holds = rig.holds
        var seenAtRotate: (settled: Bool, held: Bool)?
        var seenAtMe: (marker: Bool, secret: String?, held: Bool, settled: Bool)?
        rig.transport.onRotate = {
            seenAtRotate = (FileManager.default.fileExists(atPath: settledFile.path), holds.isHeld)
            return self.rotated()
        }
        rig.transport.onMe = {
            seenAtMe = (secrets.hasInstallMarker(), secrets.credential()?.deviceSecret, holds.isHeld,
                        FileManager.default.fileExists(atPath: settledFile.path))
            return self.me(duos: [])
        }

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, .ready, "nothing listed: the restore settles without a question")
        XCTAssertEqual(rig.transport.calls, [.rotate, .me], "the rotate goes first, so any other holder of the secret is locked out")
        XCTAssertEqual(rig.transport.rotatedAs, [DuoFixtures.credential()], "sent as the credential the launch decided on")
        XCTAssertEqual(seenAtRotate?.settled, false, "the settled file goes before the rotate: a copy cannot pass for this phone's")
        XCTAssertEqual(seenAtRotate?.held, true, "the rotate and its save are held against suspension")
        XCTAssertEqual(seenAtMe?.secret, newSecret, "the new secret is saved before anything else is sent")
        XCTAssertEqual(seenAtMe?.marker, true, "and the marker straight after it (§3.4: rotate, marker, GET /me)")
        XCTAssertEqual(seenAtMe?.held, false, "the hold ends once the answer is kept")
        XCTAssertEqual(seenAtMe?.settled, false)
        XCTAssertTrue(rig.isSettled, "settled last")
        XCTAssertEqual(try isExcludedFromBackup(rig.settledFile), true, "so neither a restore nor another phone ever gets it")
        XCTAssertEqual(secrets.credential()?.secretVersion, 2)
        XCTAssertEqual(rig.identity.credential?.deviceSecret, newSecret, "and the API client reads the new one")
        XCTAssertEqual(rig.kit.store.memberInfo?.supportID, "ABCD1234EFGH")
        XCTAssertEqual(rig.kit.store.availability, .available)
        for _ in 0..<50 { await Task.yield() }
        rig.assertNothingAttestedOrChecked()
    }

    func testTheRestoreQuestionIsAskedOnceWithTheRightNamesAndNothingElseIsSent() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(name: "Jo", duos: [DuoFixtures.wireHeader(role: .owner)]) }
        let expected = DuoRestorePrompt(partnerName: "Sam", myName: "Jo")

        let first = await rig.identity.prepare()
        let second = await rig.identity.prepare()
        let third = await rig.identity.prepare()

        XCTAssertEqual(first, .needsRestoreChoice(expected))
        XCTAssertEqual(second, first)
        XCTAssertEqual(third, first)
        XCTAssertEqual(rig.kit.store.availability, .needsRestoreChoice(expected))
        XCTAssertEqual(rig.transport.calls, [.rotate, .me], "nothing else is sent until the person chooses")
        XCTAssertTrue(rig.kit.store.duos.isEmpty, "no duo is adopted before the answer")
        XCTAssertFalse(rig.isSettled, "not settled while the question is up")
        rig.assertNothingAttestedOrChecked()

        // Joined as the partner: the question names the owner.
        let partnerRig = self.rig()
        try partnerRig.holdCredential(marker: false)
        partnerRig.transport.onRotate = { self.rotated() }
        partnerRig.transport.onMe = { self.me(name: "Sam", duos: [DuoFixtures.wireHeader(role: .partner)]) }
        let asPartner = await partnerRig.identity.prepare()
        XCTAssertEqual(asPartner, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Jo", myName: "Sam")))
    }

    func testContinueSeedsTheListedDuosUnreadAndSettlesTheRestore() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = {
            self.me(duos: [DuoFixtures.wireHeader(role: .owner, seq: 12), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner, state: .ended)])
        }
        _ = await rig.identity.prepare()
        rig.kit.store.memberInfo = nil

        await rig.identity.continueAsRestored()

        let live = try XCTUnwrap(rig.kit.store.duo(DuoFixtures.duoID))
        XCTAssertFalse(live.syncedOnce, "each duo is read whole before this phone writes for it (§10.3)")
        XCTAssertEqual(live.cursor, 0)
        XCTAssertEqual(live.partnerDisplayName, "Sam")
        XCTAssertTrue(try XCTUnwrap(rig.kit.store.duo(otherDuoID)).hasEnded, "an ended duo comes back as its ended card")
        XCTAssertNotNil(rig.kit.store.memberInfo)
        XCTAssertTrue(rig.secrets.hasInstallMarker())
        XCTAssertTrue(rig.isSettled, "Continue settles the restore")
        XCTAssertEqual(rig.kit.store.availability, .available, "the question is cleared")
        XCTAssertEqual(rig.kit.push.reasons, [.duoStarted], "there is now a reason to hold a push token")
        rig.assertNothingAttestedOrChecked()

        let after = await rig.identity.prepare()
        XCTAssertEqual(after, .ready, "whatever waited on the launch goes on")
        XCTAssertEqual(rig.transport.calls, [.rotate, .me])

        // A second Continue has nothing to seed.
        rig.kit.store.remove(otherDuoID)
        await rig.identity.continueAsRestored()
        XCTAssertNil(rig.kit.store.duo(otherDuoID))
    }

    func testNotMeLeavesNeitherACredentialNorAMarkerNorASettledFile() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        _ = await rig.identity.prepare()

        // "Not me, start fresh" is the exit service's, which discards the identity.
        rig.identity.discard()

        XCTAssertNil(rig.secrets.credential())
        XCTAssertFalse(rig.secrets.hasInstallMarker())
        XCTAssertFalse(rig.isSettled)
        let after = await rig.identity.prepare()
        XCTAssertEqual(after, DuoIdentityLaunch.none)
        await rig.identity.continueAsRestored()
        XCTAssertTrue(rig.kit.store.duos.isEmpty, "a Continue after Not me seeds nothing")
        XCTAssertEqual(rig.transport.calls, [.rotate, .me])
    }

    func testAFailedMeAfterTheRotateIsReadAgainWithoutASecondRotate() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = nil // offline

        let first = await rig.identity.prepare()

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(rig.secrets.credential()?.deviceSecret, newSecret, "the rotate's secret was saved at once")
        XCTAssertTrue(rig.secrets.hasInstallMarker(), "and the marker with it")
        XCTAssertFalse(rig.isSettled, "but nothing is settled until GET /me has been read")

        rig.transport.onMe = { self.me(duos: []) }
        let second = await rig.identity.prepare()
        XCTAssertEqual(second, .ready)
        XCTAssertEqual(rig.transport.calls, [.rotate, .me, .me], "the read is tried again, the rotate never")
        XCTAssertTrue(rig.isSettled)
    }

    func testARelaunchAfterTheRotatesAnswerWasKeptNeverRotatesAgain() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let gate = BGate()
        rig.gated.meGate = gate
        rig.transport.onRotate = { self.rotated(version: 2) }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }

        // The rotate is answered and kept; the app is then killed while GET /me is out.
        async let abandoned = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached GET /me")

        let relaunched = self.rig(kit: DuoTestKit(secretStore: rig.kit.secretStore))
        relaunched.transport.onRotate = { self.rotated(version: 3) }
        relaunched.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        let asked = await relaunched.identity.prepare()

        XCTAssertEqual(asked, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")))
        XCTAssertEqual(relaunched.transport.calls, [.me], "a second rotate whose answer was lost would revoke this phone")
        XCTAssertEqual(relaunched.secrets.credential()?.secretVersion, 2)
        gate.release()
        _ = await abandoned
    }

    func testARelaunchWhileTheQuestionIsUpReadsAndAsksAgainWithoutRotating() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated(version: 2) }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        let asked = await rig.identity.prepare()

        // The app is killed with the question up: same Keychain, nothing else.
        let relaunched = self.rig(kit: DuoTestKit(secretStore: rig.kit.secretStore))
        relaunched.transport.onRotate = { self.rotated(version: 3) }
        relaunched.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        let askedAgain = await relaunched.identity.prepare()

        XCTAssertEqual(askedAgain, asked, "the duos are never adopted without a yes (SEC F21)")
        XCTAssertEqual(relaunched.transport.calls, [.me])
        XCTAssertEqual(relaunched.secrets.credential()?.secretVersion, 2)
        XCTAssertFalse(relaunched.isSettled)
    }

    func testAKeychainThatRefusedTheRotatedSecretIsRetriedWithoutASecondRotate() async throws {
        let kit = DuoTestKit()
        let recording = BRecordingSecretStore()
        let (identity, dependencies, folder) = identity(over: recording, kit: kit)
        try dependencies.secrets.save(DuoFixtures.credential())
        kit.transport.onRotate = { self.rotated() }
        kit.transport.onMe = { self.me(duos: []) }

        recording.failWrites = true
        let first = await identity.prepare()
        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(identity.credential?.deviceSecret, newSecret, "the new secret is held in memory: the old one is already revoked")
        XCTAssertEqual(dependencies.secrets.credential(), DuoFixtures.credential(), "the Keychain refused it")
        XCTAssertFalse(dependencies.secrets.hasInstallMarker())

        let stillRefused = await identity.prepare()
        XCTAssertEqual(stillRefused, .unavailable)
        XCTAssertEqual(kit.transport.calls, [.rotate], "only the save is tried again, never the rotate")

        recording.failWrites = false
        let saved = await identity.prepare()
        XCTAssertEqual(saved, .ready)
        XCTAssertEqual(kit.transport.calls, [.rotate, .me])
        XCTAssertEqual(dependencies.secrets.credential()?.deviceSecret, newSecret)
        XCTAssertTrue(dependencies.secrets.hasInstallMarker())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("duo.settled").path))
    }

    func testAClearedDuoIsNeitherOfferedNorSeeded() async throws {
        // Cleared and alone: nothing to ask, nothing to seed.
        let alone = rig()
        try alone.holdCredential(marker: false)
        alone.kit.dependencies.cache.markCleared(DuoFixtures.duoID, now: alone.kit.clock.now)
        alone.transport.onRotate = { self.rotated() }
        alone.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(state: .ended)]) }
        let settled = await alone.identity.prepare()
        XCTAssertEqual(settled, .ready)
        XCTAssertTrue(alone.kit.store.duos.isEmpty)
        XCTAssertTrue(alone.isSettled)

        // Cleared and listed first: the question is about the other one, and only that is seeded.
        let mixed = rig()
        try mixed.holdCredential(marker: false)
        mixed.kit.dependencies.cache.markCleared(DuoFixtures.duoID, now: mixed.kit.clock.now)
        var other = DuoFixtures.wireHeader(id: otherDuoID, role: .owner, state: .ended)
        other.partnerDisplayName = "Alex"
        mixed.transport.onRotate = { self.rotated() }
        mixed.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(), other]) }
        let asked = await mixed.identity.prepare()
        XCTAssertEqual(asked, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Alex", myName: "Jo")),
                       "a cleared active duo is not preferred over an ended one the person kept")
        await mixed.identity.continueAsRestored()
        XCTAssertEqual(mixed.kit.store.duos.map(\.id), [otherDuoID])
    }

    func testARestoreOntoAPhoneThatHoldsDuosAsksNothingAndReadsThemAgain() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let ended = UUID()
        rig.kit.store.upsert(DuoFixtures.duo(cursor: 7, syncedOnce: true))
        rig.kit.store.upsert(DuoFixtures.duo(id: ended, ended: true, cursor: 4, syncedOnce: true))
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner)]) }

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, .ready, "the backup brought the cache along: there is nothing to ask")
        XCTAssertTrue(rig.isSettled)
        let held = try XCTUnwrap(rig.kit.store.duo(DuoFixtures.duoID))
        XCTAssertFalse(held.syncedOnce, "last read by the phone the backup came from: read whole before writing (§3.4 step 4)")
        XCTAssertEqual(held.cursor, 0)
        XCTAssertEqual(held.partnerDisplayName, "Sam", "and otherwise kept as it was")
        XCTAssertEqual(rig.kit.store.duo(ended)?.cursor, 4, "an ended duo is never written, so it is left alone")
        let added = try XCTUnwrap(rig.kit.store.duo(otherDuoID))
        XCTAssertFalse(added.syncedOnce)
        XCTAssertEqual(added.myRole, .partner)
    }

    /// The duos are reseated and added first and the settled file is written last, so a process
    /// killed part way through has settled nothing and the next launch does it all again.
    func testSettlingWritesTheSettledFileOnlyAfterTheDuos() async throws {
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let settledPath = folder.appendingPathComponent("duo.settled").path
        let suite = "DuoIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cache = DuoCache(defaults: defaults)
        var settledAtEachSave: [Bool] = []
        let store = DuoStore(cache: cache, usesServer: true, reloadWidget: { settledAtEachSave.append(FileManager.default.fileExists(atPath: settledPath)) })
        let transport = FakeDuoTransport()
        let dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: TestClock(),
                                           random: TestRandom(), client: DuoClientInfo(marketingVersion: "2.0", build: "57"),
                                           attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        dependencies.transport = transport
        store.install(dependencies)
        let identity = DuoIdentity(dependencies: dependencies, directory: folder, holdInBackground: BHoldRecorder().hold)
        dependencies.identity = identity
        try dependencies.secrets.save(DuoFixtures.credential())
        store.upsert(DuoFixtures.duo(cursor: 7, syncedOnce: true))
        settledAtEachSave = []
        transport.onRotate = { self.rotated() }
        transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner)]) }

        let answer = await identity.prepare()

        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(settledAtEachSave, [false, false], "the reseat and the new duo are saved before the restore is settled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settledPath))
    }

    // MARK: - A reinstall on the same phone

    /// The Keychain outlives the app, so a same-phone reinstall finds the credential and the
    /// marker; the settled file went with the app. A phone sold with the app deleted but not
    /// erased is this case too: the buyer must be asked before the seller's duos appear.
    func testASamePhoneReinstallAsksWithoutRotating() async throws {
        let rig = rig()
        try rig.holdCredential(marker: true, settled: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(name: "Jo", duos: [DuoFixtures.wireHeader()]) }

        let asked = await rig.identity.prepare()

        XCTAssertEqual(asked, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")))
        XCTAssertEqual(rig.transport.calls, [.me], "no rotate: the contract's rotate cannot safely be repeated")
        XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential())
        XCTAssertTrue(rig.kit.store.duos.isEmpty)
        XCTAssertEqual(rig.holds.holds, 0, "nothing to hold: no rotate")

        await rig.identity.continueAsRestored()
        XCTAssertTrue(rig.isSettled)
        XCTAssertEqual(rig.kit.store.duos.map(\.id), [DuoFixtures.duoID])
        let after = await rig.identity.prepare()
        XCTAssertEqual(after, .ready)
        for _ in 0..<50 { await Task.yield() }
        rig.assertNothingAttestedOrChecked()

        // With nothing listed it settles without asking.
        let empty = self.rig()
        try empty.holdCredential(marker: true, settled: false)
        empty.transport.onMe = { self.me(duos: []) }
        let settled = await empty.identity.prepare()
        XCTAssertEqual(settled, .ready)
        XCTAssertEqual(empty.transport.calls, [.me])
        XCTAssertTrue(empty.isSettled)
    }

    // MARK: - The launch answer follows the identity

    func testTheLaunchAnswerFollowsStoreDiscardAndContinue() async throws {
        let rig = rig()
        let fresh = await rig.identity.prepare()
        XCTAssertEqual(fresh, DuoIdentityLaunch.none)

        try rig.identity.store(DuoFixtures.credential())
        XCTAssertTrue(rig.isSettled, "a freshly minted identity has nothing to ask")
        let minted = await rig.identity.prepare()
        XCTAssertEqual(minted, .ready, "a first mint does not leave the launch saying there is no identity")

        rig.identity.discard()
        let discarded = await rig.identity.prepare()
        XCTAssertEqual(discarded, DuoIdentityLaunch.none)

        try rig.identity.store(DuoFixtures.credential())
        let reconnected = await rig.identity.prepare()
        XCTAssertEqual(reconnected, .ready, "a Reconnect that replaced a discarded identity")
        XCTAssertTrue(rig.transport.calls.isEmpty, "none of it sends anything")

        // The next launch of a minted identity is an ordinary one.
        let relaunched = self.rig(kit: DuoTestKit(secretStore: rig.kit.secretStore), directory: rig.directory)
        let ordinary = await relaunched.identity.prepare()
        XCTAssertEqual(ordinary, .ready)
        XCTAssertTrue(relaunched.transport.calls.isEmpty)

        // A tap that stores a new identity while the restore question is up unblocks whatever waits.
        let asked = self.rig()
        try asked.holdCredential(marker: false)
        asked.transport.onRotate = { self.rotated() }
        asked.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        _ = await asked.identity.prepare()
        try asked.identity.store(DuoCredential(memberID: "m2", deviceID: "d2", deviceSecret: String(repeating: "t", count: 43)))
        let replaced = await asked.identity.prepare()
        XCTAssertEqual(replaced, .ready)
        await asked.identity.continueAsRestored()
        XCTAssertTrue(asked.kit.store.duos.isEmpty, "the old question's answer went with the identity it was about")
    }

    // MARK: - Failures

    /// A rotate that never answered may or may not have reached the server; there is no way to
    /// tell under the frozen contract, so it is tried again. If it did arrive, this phone now
    /// holds a revoked secret: a known limitation, the server's to solve.
    func testARotateThatNeverAnsweredIsNotAnAnswerAndTheNextCallTriesAgain() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = nil // offline

        let first = await rig.identity.prepare()

        XCTAssertEqual(first, .unavailable)
        XCTAssertFalse(rig.secrets.hasInstallMarker())
        XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential(), "nothing changed")
        XCTAssertEqual(rig.kit.store.diagnostics.recentErrors.count, 1, "noted like every other failure")
        let second = await rig.identity.prepare()
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(rotates(rig.transport), 2)

        rig.transport.onRotate = { throw self.failure(.maintenance, status: 503) }
        let paused = await rig.identity.prepare()
        XCTAssertEqual(paused, .unavailable)
        XCTAssertEqual(rig.kit.store.availability, .maintenance)
    }

    func testAnUnknownIdentityIsForgottenWithEveryItemUnderItsServiceButNotTheAgeRefusal() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        // Restored with the credential: a link secret for a duo the cache does not hold, and the
        // age refusal, which is not the identity's.
        try rig.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: otherDuoID)
        try rig.secrets.markAgeRefused()
        rig.kit.attester.keys = [DuoFixtures.credential().deviceID]
        rig.transport.onRotate = { throw self.failure(.unauthenticated, status: 401) }

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, DuoIdentityLaunch.none, "a new identity is made on the next Create or Join tap, never here (§3.4)")
        XCTAssertNil(rig.identity.credential)
        XCTAssertTrue(rig.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty,
                      "the restored link secret goes too: nothing under the service belongs to a live identity")
        XCTAssertTrue(rig.secrets.isAgeRefused(), "the refusal is under its own service and stays (D60)")
        XCTAssertTrue(rig.kit.attester.keys.isEmpty, "the attestation key belonged to the device the server forgot")
        let again = await rig.identity.prepare()
        XCTAssertEqual(again, DuoIdentityLaunch.none)
        XCTAssertEqual(rig.transport.calls, [.rotate])

        // The same answer from `GET /me` after a good rotate.
        let late = self.rig()
        try late.holdCredential(marker: false)
        try late.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: otherDuoID)
        late.transport.onRotate = { self.rotated() }
        late.transport.onMe = { throw self.failure(.unauthenticated, status: 401) }
        let lateAnswer = await late.identity.prepare()
        XCTAssertEqual(lateAnswer, DuoIdentityLaunch.none)
        XCTAssertTrue(late.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty,
                      "the rotated secret, the marker and the link secret do not survive an identity the server forgot")
    }

    func testARevokedDeviceIsTheDisconnectedQuestion() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { throw self.failure(.deviceRevoked, status: 401) }

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, .disconnected)
        XCTAssertEqual(rig.kit.store.availability, .disconnected, "\"This phone was disconnected from the duo\" with I had a duo and Start fresh")
        XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential(), "kept: Start fresh or a reconnect decides")
        XCTAssertFalse(rig.secrets.hasInstallMarker())
        let again = await rig.identity.prepare()
        XCTAssertEqual(again, .disconnected)
        XCTAssertEqual(rotates(rig.transport), 1, "an answer, so it is not asked again this launch")
    }

    func testABanOrAnUpdateNeededIsNotedAndIsNotAnAnswer() async throws {
        for (code, status, availability) in [(DuoErrorCode.banned, 403, DuoAvailability.banned), (.upgradeRequired, 426, .upgradeRequired)] {
            let rig = rig()
            try rig.holdCredential(marker: false)
            rig.transport.onRotate = { throw self.failure(code, status: status) }
            let answer = await rig.identity.prepare()
            XCTAssertEqual(answer, .unavailable)
            XCTAssertEqual(rig.kit.store.availability, availability)
            XCTAssertFalse(rig.secrets.hasInstallMarker())
            XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential())
        }
    }

    // MARK: - Races

    func testCallersThatArriveTogetherShareOneLaunch() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let gate = BGate()
        rig.gated.rotateGate = gate
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: []) }

        async let first = rig.identity.prepare()
        async let second = rig.identity.prepare()
        async let third = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached its rotate")
        for _ in 0..<100 { await Task.yield() }
        gate.release()
        let answers = await [first, second, third]

        XCTAssertEqual(answers, [.ready, .ready, .ready])
        XCTAssertEqual(gate.entered, 1, "one rotate, however many asked")
        XCTAssertEqual(rig.transport.calls, [.rotate, .me])
    }

    func testAWipeWhileMeIsOutDropsItsAnswer() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let gate = BGate()
        rig.gated.meGate = gate
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached GET /me")
        rig.kit.store.resetLocalState()
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, .unavailable)
        XCTAssertNil(rig.kit.store.memberInfo, "a late answer must not write the member back")
        if case .needsRestoreChoice = rig.kit.store.availability { XCTFail("nor ask about the duo it listed") }
        XCTAssertTrue(rig.kit.store.duos.isEmpty)
        XCTAssertFalse(rig.isSettled)
    }

    func testStartingFreshWhileTheRotateIsOutDoesNotBringTheCredentialBack() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let gate = BGate()
        rig.gated.rotateGate = gate
        rig.transport.onRotate = { self.rotated() }

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached its rotate")
        rig.identity.discard()
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, DuoIdentityLaunch.none)
        XCTAssertNil(rig.secrets.credential(), "the rotated secret is not written into a credential the person discarded")
        XCTAssertFalse(rig.secrets.hasInstallMarker())
        XCTAssertNil(rig.identity.credential)
        XCTAssertEqual(rig.transport.calls, [.rotate])
    }

    func testA401AboutACredentialReplacedMeanwhileIsDropped() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        let gate = BGate()
        rig.gated.rotateGate = gate
        rig.transport.onRotate = { throw self.failure(.unauthenticated, status: 401) }
        let replacement = DuoCredential(memberID: "m2", deviceID: "d2", deviceSecret: String(repeating: "t", count: 43))

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached its rotate")
        try rig.identity.store(replacement)
        try rig.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: DuoFixtures.duoID)
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, .ready, "the identity stored meanwhile is the answer")
        XCTAssertEqual(rig.secrets.credential(), replacement, "a 401 about the old credential must not discard the new one")
        XCTAssertNotNil(rig.secrets.linkSecret(forDuo: DuoFixtures.duoID), "nor wipe what belongs to it")
        XCTAssertEqual(rig.kit.store.diagnostics.recentErrors.first?.code, "unauthenticated", "it is still in Diagnostics")
    }

    // MARK: - store, replaceSecret, discard

    func testStoreWritesTheCredentialToMoveWithARestoreAndTheMarkerToStay() throws {
        let kit = DuoTestKit()
        let recording = BRecordingSecretStore()
        let (identity, dependencies, folder) = identity(over: recording, kit: kit)

        try identity.store(DuoFixtures.credential())

        let writes = recording.writes
        let credentialItem = "\(DuoSecrets.service)/\(DuoSecrets.deviceAccount)"
        let markerItem = "\(DuoSecrets.service)/\(DuoSecrets.installMarkerAccount)"
        XCTAssertEqual(writes.map(\.item), [markerItem, credentialItem])
        XCTAssertEqual(writes.first { $0.item == credentialItem }?.accessibility, .afterFirstUnlock,
                       "not ThisDeviceOnly: it survives a restore, so a reinstall can notice it (§3.2)")
        XCTAssertEqual(writes.first { $0.item == markerItem }?.accessibility, .afterFirstUnlockThisDeviceOnly, "never leaves this phone")
        XCTAssertEqual(dependencies.secrets.credential(), DuoFixtures.credential())
        XCTAssertEqual(identity.credential, DuoFixtures.credential())
        let settled = folder.appendingPathComponent("duo.settled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settled.path), "a freshly minted identity is settled")
        XCTAssertEqual(try isExcludedFromBackup(settled), true)

        // A second identity on the same install keeps the marker it has.
        try identity.store(DuoCredential(memberID: "m2", deviceID: "d2", deviceSecret: String(repeating: "t", count: 43)))
        XCTAssertEqual(recording.writes.filter { $0.item == markerItem }.count, 1)
    }

    func testReplacingTheSecretKeepsEverythingElseAndNeedsACredential() throws {
        let rig = rig()
        XCTAssertThrowsError(try rig.identity.replaceSecret(newSecret, version: 2)) { error in
            XCTAssertEqual(error as? DuoIdentityError, .noCredential)
        }
        XCTAssertNil(rig.secrets.credential(), "nothing is made up from a secret alone")

        // Only the identity writes the credential, so a phone that holds one is a new launch.
        let holding = self.rig()
        try holding.holdCredential(marker: true)
        try holding.identity.replaceSecret(newSecret, version: 5)
        var expected = DuoFixtures.credential()
        expected.deviceSecret = newSecret
        expected.secretVersion = 5
        XCTAssertEqual(holding.secrets.credential(), expected)
        XCTAssertEqual(holding.identity.credential, expected)
    }

    func testDiscardTakesTheCredentialTheMarkerTheSettledFileAndTheAttestationKeys() async throws {
        let rig = rig()
        try rig.identity.store(DuoFixtures.credential())
        let deviceID = DuoFixtures.credential().deviceID
        try rig.secrets.store.write(Data("key-1".utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: deviceID),
                                    accessibility: .afterFirstUnlockThisDeviceOnly)
        try rig.secrets.store.write(Data("key-2".utf8), service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount,
                                    accessibility: .afterFirstUnlockThisDeviceOnly)
        try rig.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: DuoFixtures.duoID)

        rig.identity.discard()

        XCTAssertNil(rig.secrets.credential())
        XCTAssertNil(rig.identity.credential)
        XCTAssertFalse(rig.secrets.hasInstallMarker())
        XCTAssertFalse(rig.isSettled)
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), [DuoSecrets.linkSecretAccount(duoID: DuoFixtures.duoID)],
                       "both attestation items go; link secrets are per duo, and the exit service's to take")
        let answer = await rig.identity.prepare()
        XCTAssertEqual(answer, DuoIdentityLaunch.none)
    }

    func testDiscardOffTheMainThreadForgetsTheAttestationKeysBeforeItReturns() throws {
        let rig = rig()
        try rig.identity.store(DuoFixtures.credential())
        let deviceID = DuoFixtures.credential().deviceID
        try rig.secrets.store.write(Data("key-1".utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: deviceID),
                                    accessibility: .afterFirstUnlockThisDeviceOnly)
        try rig.secrets.store.write(Data("key-2".utf8), service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount,
                                    accessibility: .afterFirstUnlockThisDeviceOnly)
        let identity = rig.identity
        let secretStore = rig.kit.secretStore
        let done = expectation(description: "discarded on a background thread")
        let remaining = BAccounts()
        Thread.detachNewThread {
            XCTAssertFalse(Thread.isMainThread)
            identity.discard()
            remaining.set(secretStore.accounts(service: DuoSecrets.service))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(remaining.value, [], "gone by the time discard returned, with no task left to run")
    }

    // MARK: - The install day

    func testTheInstallDayIsStableAndKeptOutOfBackups() throws {
        let folder = BRig.temporaryDirectory()
        let first = rig(directory: folder)
        let today = first.kit.clock.today

        XCTAssertEqual(first.identity.installDay, today, "no file yet: the install day is today")
        XCTAssertEqual(first.identity.installDay, today)
        XCTAssertEqual(try String(contentsOf: first.installFile, encoding: .utf8), today, "kept as the day itself, never as a file date")
        XCTAssertEqual(try isExcludedFromBackup(first.installFile), true, "a restore or a reinstall starts it again from today (§3.2, §10.5)")

        // Another launch, days later, reads the same day.
        let later = rig(kit: DuoTestKit(now: first.kit.clock.now.addingTimeInterval(5 * 86_400)), directory: folder)
        XCTAssertNotEqual(later.kit.clock.today, today)
        XCTAssertEqual(later.identity.installDay, today)
    }

    func testADamagedInstallFileIsWrittenAgainWithToday() throws {
        let folder = BRig.temporaryDirectory()
        let first = rig(directory: folder)
        _ = first.identity.installDay
        for damage in ["not a day", "2026-13-45", "", "\u{FFFD}\u{FFFD}"] {
            try Data(damage.utf8).write(to: first.installFile)
            let later = rig(kit: DuoTestKit(now: first.kit.clock.now.addingTimeInterval(3 * 86_400)), directory: folder)
            XCTAssertEqual(later.identity.installDay, later.kit.clock.today, "\(damage.debugDescription) is not a day")
            XCTAssertEqual(try String(contentsOf: first.installFile, encoding: .utf8), later.kit.clock.today)
        }
    }

    // MARK: - Threads

    func testTheCredentialCanBeReadFromManyThreadsWhileItChanges() throws {
        let rig = rig()
        try rig.identity.store(DuoFixtures.credential())
        let identity = rig.identity
        let deviceID = DuoFixtures.credential().deviceID
        let mismatches = BCounter()
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index % 10 == 0 {
                try? identity.replaceSecret(String(repeating: "r", count: 43), version: index)
            } else if identity.credential?.deviceID != deviceID {
                mismatches.add()
            }
        }
        XCTAssertEqual(mismatches.value, 0, "every reader saw a whole credential")
        XCTAssertEqual(identity.credential?.deviceSecret, String(repeating: "r", count: 43))
        XCTAssertEqual(rig.secrets.credential(), identity.credential, "and memory and the Keychain agree at the end")
    }

    // MARK: - The verifiers' findings (round 3)

    /// A store whose widget reload is the test's hook: it runs on every saved change to a duo, so
    /// a test can see what was on disk at that moment, or act there.
    private func hookedIdentity(onSave: @escaping () -> Void) -> (DuoIdentity, DuoStore, DuoDependencies, FakeDuoTransport, URL) {
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let suite = "DuoIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cache = DuoCache(defaults: defaults)
        let store = DuoStore(cache: cache, usesServer: true, reloadWidget: onSave)
        let transport = FakeDuoTransport()
        let dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: TestClock(),
                                           random: TestRandom(), client: DuoClientInfo(marketingVersion: "2.0", build: "57"),
                                           attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        dependencies.transport = transport
        store.install(dependencies)
        let identity = DuoIdentity(dependencies: dependencies, directory: folder, holdInBackground: BHoldRecorder().hold)
        dependencies.identity = identity
        return (identity, store, dependencies, transport, folder)
    }

    /// B2: on a phone sold with the app deleted, the member `GET /me` describes is the seller.
    /// Nothing of it is kept, in memory or in the App Group, before the question is answered.
    func testTheQuestionWritesNoMemberRecordUntilContinue() async throws {
        for marker in [true, false] { // a reinstall (no rotate) and a restore (one rotate)
            let rig = rig()
            try rig.holdCredential(marker: marker)
            rig.transport.onRotate = { self.rotated() }
            rig.transport.onMe = { self.me(name: "Seller", duos: [DuoFixtures.wireHeader()]) }

            let asked = await rig.identity.prepare()

            guard case .needsRestoreChoice = asked else { XCTFail("\(asked)"); continue }
            XCTAssertNil(rig.kit.store.memberInfo, "the seller's name, Support ID and devices are not kept before a yes")
            XCTAssertNil(rig.kit.dependencies.cache.loadMember(), "nor written to the App Group")
            await rig.identity.continueAsRestored()
            XCTAssertEqual(rig.kit.store.memberInfo?.displayName, "Seller")
            XCTAssertEqual(rig.kit.dependencies.cache.loadMember()?.supportID, "ABCD1234EFGH")
        }
    }

    /// M4: a tap that stores another identity while an unsettled launch's `GET /me` is out: the
    /// answer is about the old credential, and none of it is kept.
    func testAStoreWhileAnUnsettledReadIsOutDropsItsAnswer() async throws {
        let rig = rig()
        try rig.holdCredential(marker: true)
        let gate = BGate()
        rig.gated.meGate = gate
        rig.transport.onMe = { self.me(name: "Seller", duos: [DuoFixtures.wireHeader()]) }

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached GET /me")
        try rig.identity.store(DuoCredential(memberID: "m2", deviceID: "d2", deviceSecret: String(repeating: "t", count: 43)))
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, .ready, "the identity stored meanwhile is the answer")
        XCTAssertNil(rig.kit.store.memberInfo, "the old credential's member is not written under the new one")
        if case .needsRestoreChoice = rig.kit.store.availability { XCTFail("nor its question asked") }
        XCTAssertTrue(rig.kit.store.duos.isEmpty)
        let next = await rig.identity.prepare()
        XCTAssertEqual(next, .ready)
        XCTAssertEqual(rig.transport.calls, [.me])
    }

    func testStartingFreshWhileAnUnsettledReadIsOutWritesNothing() async throws {
        let rig = rig()
        try rig.holdCredential(marker: true)
        let gate = BGate()
        rig.gated.meGate = gate
        rig.transport.onMe = { self.me(duos: []) } // nothing listed: it would settle

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached GET /me")
        rig.identity.discard()
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, DuoIdentityLaunch.none)
        XCTAssertTrue(rig.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty, "no marker written back")
        XCTAssertFalse(rig.isSettled)
        XCTAssertNil(rig.kit.store.memberInfo)
    }

    /// B4: "Start fresh" from another thread in the middle of a Continue (driven through the
    /// store's save hook, at the first duo Continue writes). Continue stops there: no marker, no
    /// settled file, and no `.ready` for an identity that is gone.
    func testAStartFreshFromAnotherThreadDuringContinueLeavesNothingSettled() async throws {
        var discardAt: DuoIdentity?
        var fired = false
        let (identity, store, dependencies, transport, folder) = hookedIdentity(onSave: {
            guard !fired, let identity = discardAt else { return }
            fired = true
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread { identity.discard(); done.signal() }
            done.wait()
        })
        try dependencies.secrets.save(DuoFixtures.credential())
        try dependencies.secrets.writeInstallMarker(random: TestRandom())
        transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner)]) }
        let asked = await identity.prepare()
        guard case .needsRestoreChoice = asked else { return XCTFail("\(asked)") }

        discardAt = identity
        await identity.continueAsRestored()

        XCTAssertTrue(fired)
        XCTAssertNil(identity.credential)
        XCTAssertFalse(dependencies.secrets.hasInstallMarker(), "Continue wrote no marker after the discard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("duo.settled").path), "nor the settled file")
        XCTAssertEqual(store.duos.count, 1, "it stopped at the duo it was writing")
        XCTAssertNotEqual(store.availability, .available)
        let after = await identity.prepare()
        XCTAssertEqual(after, DuoIdentityLaunch.none, "not .ready: there is no identity")
    }

    /// M5b: Continue writes every duo before it settles, so a kill part way leaves the question
    /// to be asked again rather than a settled phone missing a duo.
    func testContinueSeedsTheDuosBeforeItWritesTheSettledFile() async throws {
        var settledAtEachSave: [Bool] = []
        var settledPath = ""
        let (identity, store, dependencies, transport, folder) = hookedIdentity(onSave: {
            settledAtEachSave.append(FileManager.default.fileExists(atPath: settledPath))
        })
        settledPath = folder.appendingPathComponent("duo.settled").path
        try dependencies.secrets.save(DuoFixtures.credential())
        try dependencies.secrets.writeInstallMarker(random: TestRandom())
        transport.onMe = { self.me(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner)]) }
        _ = await identity.prepare()
        settledAtEachSave = []

        await identity.continueAsRestored()

        XCTAssertEqual(settledAtEachSave, [false, false], "both duos are saved before the restore is settled")
        XCTAssertEqual(store.duos.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settledPath))
    }

    /// M11: a Continue with no question to answer touches nothing.
    func testAContinueWithNoQuestionPendingWritesNothing() async throws {
        let kit = DuoTestKit()
        let recording = BRecordingSecretStore()
        let (identity, dependencies, folder) = identity(over: recording, kit: kit)
        try dependencies.secrets.save(DuoFixtures.credential()) // a restored credential, nothing asked yet
        recording.clearLog()

        await identity.continueAsRestored()

        XCTAssertTrue(recording.writes.isEmpty, "no marker: \(recording.writes.map(\.item))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("duo.settled").path))
        XCTAssertTrue(kit.store.duos.isEmpty)
        XCTAssertNil(kit.store.memberInfo)
        XCTAssertTrue(kit.transport.calls.isEmpty)
        XCTAssertTrue(kit.push.reasons.isEmpty)
    }

    /// M10: the credential reads and the marker does not. Not known, so not a restore: no
    /// rotate, nothing written or deleted, the settled file left as it is.
    func testAnUnreadableMarkerAloneIsNotAnAnswer() async throws {
        for settled in [true, false] {
            let kit = DuoTestKit()
            let recording = BRecordingSecretStore()
            let (identity, dependencies, folder) = identity(over: recording, kit: kit)
            try dependencies.secrets.save(DuoFixtures.credential())
            try dependencies.secrets.writeInstallMarker(random: kit.random)
            let settledFile = folder.appendingPathComponent("duo.settled")
            if settled {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: settledFile)
            }
            recording.refuseReads(of: [DuoSecrets.installMarkerAccount])
            recording.clearLog()
            kit.transport.onRotate = { self.rotated() }

            let answer = await identity.prepare()

            XCTAssertEqual(answer, .unavailable)
            XCTAssertEqual(identity.credential, DuoFixtures.credential(), "the account that could be read is")
            XCTAssertTrue(kit.transport.calls.isEmpty, "no rotate")
            XCTAssertTrue(recording.writes.isEmpty)
            XCTAssertTrue(recording.deletes.isEmpty)
            XCTAssertEqual(FileManager.default.fileExists(atPath: settledFile.path), settled, "the settled file is not deleted")
        }
    }

    /// B5: a settled file the restore cannot remove (a backup brought it, its exclusion having
    /// failed, and the folder refuses the delete). Taken for settled after the rotate it would
    /// skip the question on the next launch, so the restore does not start.
    func testASettledFileTheRestoreCannotRemoveStopsItBeforeTheRotate() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        try rig.markSettled()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.directory.path)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }

        let answer = await rig.identity.prepare()

        XCTAssertEqual(answer, .unavailable)
        XCTAssertTrue(rig.transport.calls.isEmpty, "no rotate")
        XCTAssertTrue(rig.isSettled, "the copy could not be removed")
        XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential())
        XCTAssertFalse(rig.secrets.hasInstallMarker())

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.directory.path)
        let after = await rig.identity.prepare()
        XCTAssertEqual(after, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), "once it can go, the restore goes on")
        XCTAssertEqual(rig.transport.calls, [.rotate, .me])
    }

    /// B5: a settled file or an install day that cannot be kept out of backups is not left where
    /// a backup could carry it to another phone.
    func testAFileThatCannotBeKeptOutOfBackupsIsNotLeft() async throws {
        let rig = rig(excludeFromBackup: { _ in throw DuoKeychainError(status: errSecIO) })

        try rig.identity.store(DuoFixtures.credential())

        XCTAssertFalse(rig.isSettled, "not settled rather than settled in a file a backup could carry")
        XCTAssertEqual(rig.identity.installDay, rig.kit.clock.today, "the day still answers for this launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.installFile.path))

        // The next launch reads GET /me and settles; it never rotates.
        let relaunched = self.rig(kit: DuoTestKit(secretStore: rig.kit.secretStore), directory: rig.directory)
        relaunched.transport.onMe = { self.me(duos: []) }
        let answer = await relaunched.identity.prepare()
        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(relaunched.transport.calls, [.me])
        XCTAssertTrue(relaunched.isSettled)
    }

    /// B6: `replaceSecret` takes a rotate's path: in memory at once, a refused save retried by the
    /// next call, never a rotate for it.
    func testReplacingTheSecretTakesTheRotationsPathAndARefusedSaveIsRetried() async throws {
        let kit = DuoTestKit()
        let recording = BRecordingSecretStore()
        let (identity, dependencies, _) = identity(over: recording, kit: kit)
        try identity.store(DuoFixtures.credential())
        let ready = await identity.prepare()
        XCTAssertEqual(ready, .ready)

        recording.failWrites = true
        XCTAssertThrowsError(try identity.replaceSecret(newSecret, version: 2))
        XCTAssertEqual(identity.credential?.deviceSecret, newSecret, "the server already refuses the old one")
        XCTAssertEqual(dependencies.secrets.credential()?.deviceSecret, DuoFixtures.credential().deviceSecret)
        let refused = await identity.prepare()
        XCTAssertEqual(refused, .unavailable, "a kept answer does not hide a secret the Keychain has not taken")

        recording.failWrites = false
        let saved = await identity.prepare()
        XCTAssertEqual(saved, .ready)
        XCTAssertEqual(dependencies.secrets.credential()?.deviceSecret, newSecret)
        XCTAssertEqual(dependencies.secrets.credential()?.secretVersion, 2)
        XCTAssertTrue(kit.transport.calls.isEmpty, "a save, never a rotate")
    }

    func testReplacingTheSecretWhileARequestIsOutDropsItsAnswer() async throws {
        let rig = rig()
        try rig.holdCredential(marker: true) // unsettled: the launch reads GET /me
        let gate = BGate()
        rig.gated.meGate = gate
        rig.transport.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        let handed = String(repeating: "h", count: 43)

        async let launched = rig.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the launch reached GET /me")
        try rig.identity.replaceSecret(handed, version: 7)
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, .unavailable, "the answer was to a request sent with the secret that was replaced")
        if case .needsRestoreChoice = rig.kit.store.availability { XCTFail("so nothing of it is acted on") }
        XCTAssertEqual(rig.secrets.credential()?.deviceSecret, handed)
        XCTAssertEqual(rig.secrets.credential()?.secretVersion, 7)
    }

    /// Item 2 of the re-verification: on a restored phone (no marker) a new secret would write the
    /// marker and turn the restore's lock-out rotate into an unsettled launch. It is refused, it
    /// changes nothing, and the launch still makes its one rotate.
    func testReplacingTheSecretOnARestoredPhoneIsRefusedAndTheRestoreStillRotates() async throws {
        let rig = rig()
        try rig.holdCredential(marker: false)
        rig.transport.onRotate = { self.rotated() }
        rig.transport.onMe = { self.me(duos: []) }

        XCTAssertThrowsError(try rig.identity.replaceSecret(String(repeating: "h", count: 43), version: 7)) { error in
            XCTAssertEqual(error as? DuoIdentityError, .noInstallMarker)
        }
        XCTAssertEqual(rig.identity.credential, DuoFixtures.credential(), "nothing changed in memory")
        XCTAssertEqual(rig.secrets.credential(), DuoFixtures.credential(), "or in the Keychain")
        XCTAssertFalse(rig.secrets.hasInstallMarker(), "and no marker was written")

        let answer = await rig.identity.prepare()
        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(rig.transport.rotatedAs, [DuoFixtures.credential()], "the restore still locks the other copy out")
    }

    /// B7: once read, the credential is served from memory; a Keychain that stops answering never
    /// makes an existing identity look missing. Only `discard()` forgets it.
    func testTheCredentialIsServedFromMemoryOnceReadAndOnlyDiscardForgetsIt() throws {
        let kit = DuoTestKit()
        let recording = BRecordingSecretStore()
        let (identity, dependencies, _) = identity(over: recording, kit: kit)
        try dependencies.secrets.save(DuoFixtures.credential())

        XCTAssertEqual(identity.credential, DuoFixtures.credential())
        recording.locked = true
        XCTAssertEqual(identity.credential, DuoFixtures.credential(), "a refused read after a good one changes nothing")
        identity.discard()
        XCTAssertNil(identity.credential)
        recording.locked = false
        XCTAssertNil(identity.credential)
        XCTAssertNil(dependencies.secrets.credential(), "and it is gone from the Keychain too")
    }

    /// M9: the background hold's block. iOS calls it with `expired` false and the activity lasts
    /// while that call waits; the call with `expired` true, or the release, must end the wait.
    func testTheBackgroundHoldEndsWhenTheSystemTakesTheTimeBackOrTheWorkIsDone() {
        let started = Date()
        let byExpiry = DispatchSemaphore(value: 0)
        let expiring = DuoIdentity.expiringActivityBlock(byExpiry, limit: 20)
        let expired = expectation(description: "the granted call returned on expiry")
        DispatchQueue.global().async { expiring(false); expired.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { expiring(true) }

        let byRelease = DispatchSemaphore(value: 0)
        let released = DuoIdentity.expiringActivityBlock(byRelease, limit: 20)
        let done = expectation(description: "the granted call returned on release")
        DispatchQueue.global().async { released(false); done.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { byRelease.signal() }

        wait(for: [expired, done], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "neither waited for its 20-second limit")
    }

    /// One process of one phone against `BServer`: a fresh identity over a Keychain and a folder
    /// that outlive it. A kill is making another over the same two.
    private func phoneProcess(server: BServer, keychain: DuoSecretStore, folder: URL,
                              me: @escaping @Sendable () -> DuoWireGetMeResponse) -> (DuoIdentity, BServerTransport, DuoTestKit) {
        let kit = DuoTestKit()
        let transport = BServerTransport(server: server, meAnswer: me)
        let dependencies = DuoDependencies(host: kit.store, cache: kit.dependencies.cache, secrets: DuoSecrets(store: keychain), clock: kit.clock,
                                           random: kit.random, client: kit.dependencies.client, attester: kit.attester,
                                           deviceCheck: FakeDuoDeviceCheck())
        dependencies.transport = transport
        dependencies.ops = kit.ops
        let identity = DuoIdentity(dependencies: dependencies, directory: folder, holdInBackground: BHoldRecorder().hold)
        dependencies.identity = identity
        transport.identity = identity
        kit.store.install(dependencies)
        keptAlive.append(kit.store)
        keptAlive.append(dependencies)
        return (identity, transport, kit)
    }

    /// M1b: the rotated secret is saved before the marker. When the marker write fails and the
    /// process dies, the Keychain holds the new secret without a marker: the next launch takes it
    /// for a restore and rotates once more, with a secret the server accepts, and the phone works.
    /// (Written the other way round, the marker would land and the save fail, and the relaunch
    /// would read `GET /me` with the revoked old secret: a phone locked out of its own identity.)
    func testARotatedSecretIsSavedBeforeTheMarkerSoAKillBetweenThemLeavesAWorkingPhone() async throws {
        let server = BServer()
        let original = DuoFixtures.credential()
        server.enroll(original)
        let keychain = BRecordingSecretStore()
        try DuoSecrets(store: keychain).save(original) // restored onto this phone: no marker
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let nothingListed: @Sendable () -> DuoWireGetMeResponse = { [me = self.me(duos: [])] in me }

        keychain.refuseWrites(to: [DuoSecrets.installMarkerAccount])
        let (first, _, _) = phoneProcess(server: server, keychain: keychain, folder: folder, me: nothingListed)
        let interrupted = await first.prepare()
        XCTAssertEqual(interrupted, .unavailable)
        XCTAssertEqual(server.rotations, 1)
        XCTAssertNoThrow(try server.authenticate(DuoSecrets(store: keychain).credential()), "the new secret was saved before the marker was tried")

        // The process dies; the Keychain takes writes again.
        keychain.refuseWrites(to: [])
        let (relaunched, _, _) = phoneProcess(server: server, keychain: keychain, folder: folder, me: nothingListed)
        let answer = await relaunched.prepare()

        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(server.rotations, 2, "no marker: taken for a restore and rotated once more, with a secret the server accepts")
        XCTAssertNoThrow(try server.authenticate(DuoSecrets(store: keychain).credential()), "and the phone still works")
        XCTAssertTrue(DuoSecrets(store: keychain).hasInstallMarker())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("duo.settled").path))
    }

    // MARK: - B1: the rotate goes out as the credential the launch decided on

    /// A Create, Join or Reconnect that stores another credential while the restore's rotate is on
    /// its way out (between the launch's call and the request leaving): the rotate still goes out
    /// as the restored credential, so the new one keeps its own secret and keeps working.
    func testTheRotateGoesOutAsTheDecidedCredentialWhateverIsStoredBeforeItLeaves() async throws {
        let server = BServer()
        let restored = DuoFixtures.credential()
        let tapped = DuoCredential(memberID: "7d2a0000-0000-4000-8000-0000000000aa", deviceID: "7d2a0000-0000-4000-8000-0000000000cc",
                                   deviceSecret: String(repeating: "y", count: 43))
        server.enroll(restored)
        server.enroll(tapped)
        let keychain = BRecordingSecretStore()
        try DuoSecrets(store: keychain).save(restored) // restored onto this phone: no marker
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let (identity, transport, _) = phoneProcess(server: server, keychain: keychain, folder: folder,
                                                    me: { [me = self.me(duos: [])] in me })
        let hop = BGate()
        transport.beforeSend = hop

        async let launched = identity.prepare()
        await yield(until: { hop.entered > 0 }, "the rotate is on its way out")
        try identity.store(tapped)
        hop.release()
        let answer = await launched

        XCTAssertEqual(transport.rotatedAs, [restored], "never the credential stored in the gap")
        XCTAssertEqual(answer, .ready, "the identity stored meanwhile is the answer")
        XCTAssertEqual(DuoSecrets(store: keychain).credential(), tapped, "and the rotate's answer, about the old one, was not written over it")
        XCTAssertNoThrow(try server.authenticate(DuoSecrets(store: keychain).credential()), "so the new identity is not locked out of itself")
        XCTAssertEqual(server.rotations, 1)
    }

    /// The decision is checked again just before the rotate: an identity that changed since (here
    /// in the moment the launch asks to be kept running) sends no rotate at all.
    func testNoRotateIsSentForADecisionTheIdentityHasMovedPast() async throws {
        let kit = DuoTestKit()
        try kit.dependencies.secrets.save(DuoFixtures.credential()) // restored: no marker
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let tapped = DuoCredential(memberID: "m2", deviceID: "d2", deviceSecret: String(repeating: "t", count: 43))
        let inTheGap = BAction()
        let identity = DuoIdentity(dependencies: kit.dependencies, directory: folder, holdInBackground: { _ in
            inTheGap.run()
            return {}
        })
        kit.dependencies.identity = identity
        inTheGap.set { try? identity.store(tapped) }
        kit.transport.onRotate = { self.rotated() }

        let answer = await identity.prepare()

        XCTAssertTrue(kit.transport.rotatedAs.isEmpty, "no rotate for the credential that was replaced")
        XCTAssertTrue(kit.transport.calls.isEmpty)
        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(kit.dependencies.secrets.credential(), tapped)
    }

    // MARK: - The re-verifier's killers (K1 to K7)

    /// An identity over a store whose saves are the test's hook, a clock whose next reading is
    /// another, a recording Keychain and a gated transport, for the tests that have to act in the
    /// gap between two lines of the identity.
    private func killerRig(onSave: @escaping () -> Void = {}) -> (identity: DuoIdentity, store: DuoStore, dependencies: DuoDependencies,
                                                                  fake: FakeDuoTransport, gated: BGatedTransport, clock: BHookClock,
                                                                  keychain: BRecordingSecretStore, folder: URL) {
        let folder = BRig.temporaryDirectory()
        folders.append(folder)
        let suite = "DuoIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cache = DuoCache(defaults: defaults)
        let store = DuoStore(cache: cache, usesServer: true, reloadWidget: onSave)
        let fake = FakeDuoTransport()
        let gated = BGatedTransport(fake)
        let clock = BHookClock()
        let keychain = BRecordingSecretStore()
        let dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: keychain), clock: clock, random: TestRandom(),
                                           client: DuoClientInfo(marketingVersion: "2.0", build: "57"), attester: FakeDuoAttester(),
                                           deviceCheck: FakeDuoDeviceCheck())
        dependencies.transport = gated
        dependencies.ops = FakeOpQueue()
        dependencies.push = FakePush()
        store.install(dependencies)
        let identity = DuoIdentity(dependencies: dependencies, directory: folder, holdInBackground: BHoldRecorder().hold)
        dependencies.identity = identity
        keptAlive.append(store)
        keptAlive.append(dependencies)
        return (identity, store, dependencies, fake, gated, clock, keychain, folder)
    }

    private func onAnotherThread(_ work: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { work(); done.signal() }
        done.wait()
    }

    /// K1: a Start fresh from another thread right after Continue took the answer (here, at its
    /// reading of the clock) leaves no member record and no duo.
    func testK1ADiscardRightAfterContinueTookTheAnswerWritesNoMemberRecord() async throws {
        let r = killerRig()
        try r.dependencies.secrets.save(DuoFixtures.credential())
        try r.dependencies.secrets.writeInstallMarker(random: TestRandom())
        r.fake.onMe = { self.me(duos: [DuoFixtures.wireHeader()]) }
        let asked = await r.identity.prepare()
        guard case .needsRestoreChoice = asked else { return XCTFail("\(asked)") }
        let identity = r.identity
        r.clock.arm { self.onAnotherThread { identity.discard() } }

        await r.identity.continueAsRestored()

        XCTAssertNil(r.identity.credential)
        XCTAssertNil(r.store.memberInfo, "the seller's member record is not written for an identity that is gone")
        XCTAssertNil(r.dependencies.cache.loadMember())
        XCTAssertTrue(r.store.duos.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("duo.settled").path))
    }

    /// K2: the discard lands at the LAST duo Continue writes, so only the locked settle step's own
    /// generation check stands between it and a marker, a settled file and `.ready`.
    func testK2ADiscardAtTheLastDuoContinueWritesLeavesNothingSettledAndNoReady() async throws {
        var saves = 0
        var discardAt: DuoIdentity?
        let r = killerRig(onSave: {
            saves += 1
            guard saves == 2, let identity = discardAt else { return }
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread { identity.discard(); done.signal() }
            done.wait()
        })
        try r.dependencies.secrets.save(DuoFixtures.credential())
        try r.dependencies.secrets.writeInstallMarker(random: TestRandom())
        r.fake.onMe = { self.me(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: self.otherDuoID, role: .partner)]) }
        let asked = await r.identity.prepare()
        guard case .needsRestoreChoice = asked else { return XCTFail("\(asked)") }
        saves = 0
        discardAt = r.identity

        await r.identity.continueAsRestored()

        XCTAssertEqual(saves, 2)
        XCTAssertNil(r.identity.credential)
        XCTAssertFalse(r.dependencies.secrets.hasInstallMarker(), "no marker written back after the discard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("duo.settled").path), "no settled file")
        let after = await r.identity.prepare()
        XCTAssertEqual(after, DuoIdentityLaunch.none, "not .ready: there is no identity")
        XCTAssertNotEqual(r.store.availability, .available)
    }

    /// K3: a launch already running when Continue settles (its `GET /me` out) drops its answer:
    /// the generation Continue moves is what tells it the question was answered.
    func testK3ALaunchRunningWhileContinueSettlesDropsItsAnswer() async throws {
        let r = killerRig()
        try r.dependencies.secrets.save(DuoFixtures.credential())
        try r.dependencies.secrets.writeInstallMarker(random: TestRandom())
        r.fake.onMe = { self.me(name: "Jo", duos: [DuoFixtures.wireHeader()]) }
        let asked = await r.identity.prepare()
        guard case .needsRestoreChoice = asked else { return XCTFail("\(asked)") }
        // A new secret the Keychain refuses: the kept answer no longer hides a launch.
        r.keychain.failWrites = true
        XCTAssertThrowsError(try r.identity.replaceSecret(String(repeating: "h", count: 43), version: 2))
        r.keychain.failWrites = false
        let gate = BGate()
        r.gated.meGate = gate
        r.fake.onMe = { self.me(name: "Stale", duos: [DuoFixtures.wireHeader()]) }

        async let launched = r.identity.prepare()
        await yield(until: { gate.entered > 0 }, "the second launch's GET /me is out")
        await r.identity.continueAsRestored()
        XCTAssertEqual(r.store.memberInfo?.displayName, "Jo")
        gate.release()
        let answer = await launched

        XCTAssertEqual(answer, .ready)
        XCTAssertEqual(r.store.memberInfo?.displayName, "Jo", "the late answer, read before the Continue, is not written over it")
    }

    /// K4: a tap stores another identity on another thread after the unsettled launch's `GET /me`
    /// was accepted and before its answer is remembered. The old identity's question is neither
    /// shown nor answerable, and a Continue writes nothing of it under the new identity.
    func testK4AStoreBetweenTheAcceptedReadAndTheQuestionLeavesNoQuestionBehind() async throws {
        let r = killerRig()
        try r.dependencies.secrets.save(DuoFixtures.credential())
        try r.dependencies.secrets.writeInstallMarker(random: TestRandom())
        r.fake.onMe = { self.me(name: "Seller", duos: [DuoFixtures.wireHeader()]) }
        let identity = r.identity
        let tapped = DuoCredential(memberID: "7d2a0000-0000-4000-8000-0000000000aa", deviceID: "7d2a0000-0000-4000-8000-0000000000cc",
                                   deviceSecret: String(repeating: "y", count: 43))
        r.clock.arm { self.onAnotherThread { try? identity.store(tapped) } }

        let answer = await r.identity.prepare()

        XCTAssertEqual(answer, .ready, "the identity stored meanwhile is the answer")
        if case .needsRestoreChoice = r.store.availability { XCTFail("the old identity's question is not shown") }
        await r.identity.continueAsRestored()
        XCTAssertNil(r.store.memberInfo, "nothing of the seller is written under the new identity")
        XCTAssertTrue(r.store.duos.isEmpty)
        XCTAssertEqual(r.identity.credential, tapped)
    }

    /// K5: after `discard()` the credential is gone for this process even when the Keychain
    /// refused the delete (it is not read back).
    func testK5ADiscardWhoseKeychainDeleteFailedStillForgetsTheCredential() throws {
        let r = killerRig()
        try r.dependencies.secrets.save(DuoFixtures.credential())
        XCTAssertNotNil(r.identity.credential)
        r.keychain.failDeletes = true
        r.identity.discard()
        XCTAssertNil(r.identity.credential, "a discarded identity is never served again in this process")
    }

    /// K6: a credential just stored is served from memory, even when the Keychain stops answering
    /// reads right after (a nil would make every bearer call fail before it left the phone).
    func testK6AStoredCredentialIsServedFromMemory() throws {
        let r = killerRig()
        try r.identity.store(DuoFixtures.credential())
        r.keychain.locked = true
        XCTAssertEqual(r.identity.credential, DuoFixtures.credential())
    }

    /// K7: a rotate that went through lifts a "paused" notice even when the `GET /me` after it fails
    /// offline (that failure is not a 503 and says nothing about a pause).
    func testK7ASuccessfulRotateLiftsAMaintenanceNoticeEvenWhenTheReadAfterItFails() async throws {
        let r = killerRig()
        try r.dependencies.secrets.save(DuoFixtures.credential()) // restored onto this phone: no marker
        r.store.availability = .maintenance
        r.fake.onRotate = { self.rotated() }

        let answer = await r.identity.prepare() // GET /me is offline (no handler)

        XCTAssertEqual(answer, .unavailable)
        XCTAssertEqual(r.fake.calls, [.rotate, .me])
        XCTAssertEqual(r.store.availability, .available, "the rotate went through: the service is not paused")
    }

    // MARK: - The composed app

    /// With the real identity wired in, a launch on a phone with no credential still sends,
    /// attests, checks and writes nothing (the foundation's before-a-tap test with stub services
    /// never reached `prepare()`).
    func testTheComposedAppsLaunchWithNoCredentialDoesNothing() async {
        let session = RecordingSession()
        let secretStore = DuoReviewSpySecretStore()
        let attester = FakeDuoAttester()
        let deviceCheck = DuoReviewCountingDeviceCheck()
        let suite = "DuoIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let identityFolder = BRig.temporaryDirectory()
        folders.append(identityFolder)
        let store = DuoComposition.makeLiveStore(session: session, secretStore: secretStore, cache: DuoCache(defaults: defaults),
                                                 attester: attester, deviceCheck: deviceCheck, identityDirectory: identityFolder)
        let identity = try? XCTUnwrap(store.dependencies?.identity)
        XCTAssertTrue(identity is DuoIdentity, "the real identity is the one wired in")

        let answer = await identity?.prepare()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(answer, DuoIdentityLaunch.none)
        XCTAssertTrue(session.requests.isEmpty)
        XCTAssertEqual(attester.attestedNewKeys, 0)
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertTrue(secretStore.writes.isEmpty, "\(secretStore.writes)")
        XCTAssertTrue(secretStore.deletes.isEmpty, "\(secretStore.deletes)")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: identityFolder.path)) ?? []).isEmpty, "no file before a tap")
    }
}

fileprivate final class BCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

/// Something to do once, set after the closure that runs it was handed out.
fileprivate final class BAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    func set(_ action: @escaping () -> Void) { lock.lock(); self.action = action; lock.unlock() }
    func run() {
        lock.lock(); let once = action; action = nil; lock.unlock()
        once?()
    }
}

fileprivate final class BAccounts: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String]?
    var value: [String]? { lock.lock(); defer { lock.unlock() }; return accounts }
    func set(_ new: [String]) { lock.lock(); accounts = new; lock.unlock() }
}
#endif
