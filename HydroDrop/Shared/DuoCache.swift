#if DUO_V2
import Foundation

/// Where Duo keeps what must outlive a launch, in the App Group's defaults so the widget can
/// read the duos too. Every key is new in Duo v2: `LegacyDuoCleanup` deletes the iCloud
/// Duo's keys (`duo.states.v1`, `duo.myDisplayName`, `duo.ledger.v1`, `duo.notificationsOff`,
/// `duoInviteMoment.dismissed`), and a v2 key must never share a name with something a
/// cleanup deletes (decisions D15 and the 2026-09-28 log line).
///
/// A value type over a `UserDefaults`, so a test passes a throwaway suite. It does no
/// locking of its own: `UserDefaults` is safe to call from any thread, and the app's writers
/// are all on the main actor.
struct DuoCache {
    static let statesKey = "duo.states.v2"
    static let ledgerKey = "duo.ledger.v2"
    static let myDisplayNameKey = "duo.myDisplayName.v2"
    static let opsKey = "duo.ops.v1"
    static let pendingInviteKey = "duo.pendingInvite"
    static let rejectedDaysKey = "duo.rejectedDays.v1"
    static let diagnosticsKey = "duo.diagnostics.v1"
    static let notificationsOffKey = "duo.notificationsOff.v2"
    static let inviteMomentDismissedKey = "duoInviteMoment.dismissed.v2"
    static let memberKey = "duo.member.v1"
    static let ageStatusKey = "duo.ageStatus.v1"
    static let termsAcceptedKey = "duo.termsAccepted.v1"
    static let pushUploadKey = "duo.pushUpload.v1"
    static let seenDevicesKey = "duo.seenDevices.v1"
    static let goalRaiseNoticeKey = "duo.goalRaiseNotice.v1"
    static let inflightKey = "duo.inflight.v1"
    static let clearedKey = "duo.cleared.v1"
    static let deleteRequestedKey = "duo.deleteRequested.v1"
    static let throwawayDeviceKey = "duo.throwawayDevice.v1"
    /// The kind the widget is registered under, so a change here can reload it.
    static let widgetKind = "DuoWidget"

    /// Every key this cache writes. A new key is added here and is wiped unless `keptKeys` also
    /// names it, so forgetting to decide errs towards forgetting the data rather than keeping it.
    static let allKeys = [statesKey, ledgerKey, myDisplayNameKey, opsKey, pendingInviteKey, rejectedDaysKey,
                          diagnosticsKey, notificationsOffKey, inviteMomentDismissedKey, memberKey, ageStatusKey,
                          termsAcceptedKey, pushUploadKey, seenDevicesKey, goalRaiseNoticeKey, inflightKey, clearedKey,
                          deleteRequestedKey, throwawayDeviceKey]
    /// What a wipe leaves: the age answer (a local boolean the person gave once, and what stops
    /// a restart by someone who was refused, D60), the notifications switch, and the one-time
    /// suggestion and goal-raise note. None of them says anything about a duo.
    static let keptKeys = [ageStatusKey, notificationsOffKey, inviteMomentDismissedKey, goalRaiseNoticeKey]
    /// Every key `clearEverything` removes: what a Delete my Duo data and a "Start fresh" wipe.
    static let wipedKeys = allKeys.filter { !keptKeys.contains($0) }

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults ?? .standard) {
        self.defaults = defaults
    }

    static var live: DuoCache { DuoCache() }

    // MARK: Duos

    func loadDuos() -> [DuoState] { load([DuoState].self, key: Self.statesKey) ?? [] }
    func saveDuos(_ duos: [DuoState]) { save(duos, key: Self.statesKey) }

    // MARK: The ledger of what was already announced

    func loadLedger() -> DuoLedger { DuoLedger(seen: load([String].self, key: Self.ledgerKey) ?? []) }
    func saveLedger(_ ledger: DuoLedger) { save(ledger.seen, key: Self.ledgerKey) }

    // MARK: My name, as typed

    var myDisplayName: String {
        get { defaults.string(forKey: Self.myDisplayNameKey) ?? "" }
        // An empty name is no name, so the key goes rather than being kept as an empty string.
        nonmutating set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.myDisplayNameKey) } else { defaults.set(newValue, forKey: Self.myDisplayNameKey) }
        }
    }

    // MARK: The op queue and what is waiting for a yes

    /// Entry by entry: one this build cannot decode (a damaged one, or a kind a newer build
    /// wrote) used to turn the whole queue into an empty one, and the next enqueue overwrote the
    /// rest, losing a leave or a block that was waiting.
    func loadOps() -> [DuoQueuedOp] {
        guard let data = defaults.data(forKey: Self.opsKey) else { return [] }
        if let all = try? JSONDecoder().decode([DuoQueuedOp].self, from: data) { return all }
        guard let items = try? JSONDecoder().decode([DuoCache.OpSlot].self, from: data) else { return [] }
        return items.compactMap(\.op)
    }

    private struct OpSlot: Decodable {
        let op: DuoQueuedOp?
        init(from decoder: Decoder) throws { op = try? DuoQueuedOp(from: decoder) }
    }
    func saveOps(_ ops: [DuoQueuedOp]) { save(ops, key: Self.opsKey) }

    func loadPendingInvite() -> DuoPendingInvite? { load(DuoPendingInvite.self, key: Self.pendingInviteKey) }
    func savePendingInvite(_ invite: DuoPendingInvite?) {
        if let invite { save(invite, key: Self.pendingInviteKey) } else { defaults.removeObject(forKey: Self.pendingInviteKey) }
    }

    /// Keyed by the duo's lowercase id.
    func loadRejectedDays() -> [String: DuoRejectedDays] { load([String: DuoRejectedDays].self, key: Self.rejectedDaysKey) ?? [:] }
    func saveRejectedDays(_ days: [String: DuoRejectedDays]) { save(days, key: Self.rejectedDaysKey) }

    /// The idempotent requests a tap started and has not finished (§6.0). An entry past the
    /// journal's lifetime is dropped here, from disk too: pruning only when a new request asked
    /// for a key left a typed code and a DeviceCheck token in these defaults for as long as the
    /// person did not tap again (a launch 30 days later still found them).
    func loadInflight(now: Date = Date()) -> DuoInflightJournal {
        var journal = load(DuoInflightJournal.self, key: Self.inflightKey) ?? DuoInflightJournal()
        let before = journal.entries.count
        journal.prune(now: now)
        if journal.entries.count != before {
            if journal.entries.isEmpty { defaults.removeObject(forKey: Self.inflightKey) } else { saveInflight(journal) }
        }
        return journal
    }
    func saveInflight(_ journal: DuoInflightJournal) { save(journal, key: Self.inflightKey) }

    // MARK: Duos the person cleared

    /// `GET /me` lists a duo that ended for 30 days and a Clear is local only (§12.2), so
    /// whatever reads that list asks this first or the duo comes straight back. Cleared on
    /// `clearEverything`: a new identity is a different member, which the server lists none of.
    func loadCleared() -> DuoClearedSet { load(DuoClearedSet.self, key: Self.clearedKey) ?? DuoClearedSet() }

    func markCleared(_ id: UUID, now: Date) {
        var cleared = loadCleared()
        cleared.mark(id, now: now)
        save(cleared, key: Self.clearedKey)
    }

    func isCleared(_ id: UUID, now: Date) -> Bool {
        var cleared = loadCleared()
        cleared.prune(now: now)
        return cleared.contains(id)
    }

    // MARK: Diagnostics, the member, the push upload

    func loadDiagnostics() -> DuoDiagnostics { load(DuoDiagnostics.self, key: Self.diagnosticsKey) ?? DuoDiagnostics() }
    func saveDiagnostics(_ diagnostics: DuoDiagnostics) { save(diagnostics, key: Self.diagnosticsKey) }

    func loadMember() -> DuoMemberInfo? { load(DuoMemberInfo.self, key: Self.memberKey) }
    func saveMember(_ member: DuoMemberInfo?) {
        if let member { save(member, key: Self.memberKey) } else { defaults.removeObject(forKey: Self.memberKey) }
    }

    /// The ids of the devices the person has already been told about (D45): `GET /me`'s list
    /// is compared with this one, and a device in it that is not here is new.
    func loadSeenDeviceIDs() -> [String]? { load([String].self, key: Self.seenDevicesKey) }
    func saveSeenDeviceIDs(_ ids: [String]) { save(ids, key: Self.seenDevicesKey) }
    /// For an identity the server no longer knows: the list belonged to the forgotten member,
    /// and left in place it makes this phone's own new device look like an added one (D45).
    func forgetSeenDeviceIDs() { defaults.removeObject(forKey: Self.seenDevicesKey) }

    /// What the last push upload said, so a re-upload happens only when something changed
    /// (§6.2's triggers). The token itself is kept as a hash, never as the token.
    func loadPushUpload() -> DuoPushUploadState? { load(DuoPushUploadState.self, key: Self.pushUploadKey) }
    func savePushUpload(_ state: DuoPushUploadState?) {
        if let state { save(state, key: Self.pushUploadKey) } else { defaults.removeObject(forKey: Self.pushUploadKey) }
    }

    // MARK: Small switches

    /// On until turned off. The Duo notifications toggle (§9.6).
    var notificationsEnabled: Bool {
        get { !defaults.bool(forKey: Self.notificationsOffKey) }
        nonmutating set { defaults.set(!newValue, forKey: Self.notificationsOffKey) }
    }

    var inviteMomentDismissed: Bool {
        get { defaults.bool(forKey: Self.inviteMomentDismissedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.inviteMomentDismissedKey) }
    }

    /// The one-time note on a goal raise has been shown (§8.6).
    var goalRaiseNoticeShown: Bool {
        get { defaults.bool(forKey: Self.goalRaiseNoticeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.goalRaiseNoticeKey) }
    }

    /// The answer to the birth-year screen, as a bare status. The year itself is never kept.
    var ageStatus: DuoAgeStatus {
        get { defaults.string(forKey: Self.ageStatusKey).flatMap(DuoAgeStatus.init(rawValue:)) ?? .unknown }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.ageStatusKey) }
    }

    /// The terms version this person has accepted on this phone (0 for none).
    var acceptedTermsVersion: Int {
        get { defaults.integer(forKey: Self.termsAcceptedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.termsAcceptedKey) }
    }

    /// When the person asked for `DELETE /me` and the answer was not seen to be a refusal: a bare
    /// date, no token and no request bytes (D62). If the server committed the delete and the
    /// answer was lost, the next request meets a 401 `unauthenticated` and, without this, only
    /// part of what the phone kept would be forgotten, with nothing left in the screen to finish
    /// it: the ended cards, the name, the ledger and orphan Keychain items would stay. With it,
    /// that 401 completes the wipe the person asked for (`noteFailure`). The exit service sets
    /// it before it sends and clears it when the server's answer proves nothing was deleted; a
    /// wipe removes it with everything else.
    var deleteRequestedAt: Date? {
        get { defaults.object(forKey: Self.deleteRequestedKey) is Double ? Date(timeIntervalSince1970: defaults.double(forKey: Self.deleteRequestedKey)) : nil }
        nonmutating set {
            if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: Self.deleteRequestedKey) }
            else { defaults.removeObject(forKey: Self.deleteRequestedKey) }
        }
    }

    /// The device id of the throwaway identity a Reconnect minted to carry its request and has not
    /// finished with yet. While the stored credential is that one and live duos are cached, the
    /// duos are another member's and this phone is still disconnected from them: without this,
    /// a relaunch after a refused or interrupted reconnect found a valid, settled credential and
    /// nothing to say otherwise, the first read answered `duo_unknown`, every cached duo ended
    /// locally, and a reconnect that later worked could not bring them back. A device id only.
    var throwawayDeviceID: String? {
        get { defaults.string(forKey: Self.throwawayDeviceKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.throwawayDeviceKey) }
            else { defaults.removeObject(forKey: Self.throwawayDeviceKey) }
        }
    }

    /// Forgets every duo and everything about this person's Duo identity that this phone
    /// kept in its defaults. The Keychain, the install file and the notifications are the
    /// identity code's and the exit service's to clear.
    func clearEverything() {
        for key in Self.wipedKeys { defaults.removeObject(forKey: key) }
    }

    // MARK: Plumbing

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // An unreadable cache is an empty one, never a crash (the old test "an unreadable
        // cache is an empty one"): the next fetch fills it again.
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// What the last upload of the push token said (§6.2): enough to see what changed since.
struct DuoPushUploadState: Codable, Equatable {
    /// SHA-256 of the token, hex. The token is never kept.
    var tokenHash: String
    var environment: DuoAPNsEnvironment
    var zone: String?
    var windowStart: Int?
    var windowEnd: Int?
    var enabled: Bool
    var uploadedAt: Date
}
#endif
