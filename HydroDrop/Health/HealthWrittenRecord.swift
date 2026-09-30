import Foundation
import Security

/// The two kinds of sample a drink can have in Apple Health. They are separate Health
/// types, written and replaced on their own, and a device may be allowed to write one and
/// not the other.
enum HealthSampleKind: String, CaseIterable {
    case water
    case caffeine
}

/// A drink's own figures, as Health was given them: when it was drunk, how much was poured,
/// and what it was.
///
/// Deliberately not the amount Health records. A release that changes how much of a coffee
/// counts would otherwise make every coffee look edited, and two versions of the app would
/// keep correcting each other's writes.
struct HealthFigures: Equatable {
    /// Whole milliseconds since 1970.
    let milliseconds: Int64
    let amountML: Int
    /// The raw drink type, with a drink from before drink types existed read as water. Kept
    /// raw so a type this version doesn't know is still compared as itself.
    let drinkType: String

    init(milliseconds: Int64, amountML: Int, drinkType: String) {
        self.milliseconds = milliseconds
        self.amountML = amountML
        self.drinkType = drinkType
    }

    init(of entry: WaterEntry) {
        self.init(
            milliseconds: Self.milliseconds(of: entry.timestamp),
            amountML: entry.amountML,
            drinkType: entry.drinkTypeRawValue ?? DrinkType.water.rawValue
        )
    }

    static func milliseconds(of date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
        // Held within the dates Foundation can express, so no drink's time, however odd,
        // can trap the conversion or overflow a comparison.
        let bounds = Double(plausibleMilliseconds.lowerBound)...Double(plausibleMilliseconds.upperBound)
        return Int64(min(max(milliseconds, bounds.lowerBound), bounds.upperBound))
    }

    /// Whether these are the same figures as `other`, give or take under a second.
    ///
    /// The device that logged a drink keeps its time to a fraction of a millisecond, and
    /// every other device has whatever CloudKit gave back, rounded or cut to some coarser
    /// step. Compared exactly, two devices would each see the other's writes as out of date
    /// and rewrite the same drinks forever. An edit moves a drink by at least a minute,
    /// because the time picker works in minutes, so nothing real is lost.
    func matches(_ other: HealthFigures) -> Bool {
        let (gap, overflowed) = milliseconds.subtractingReportingOverflow(other.milliseconds)
        return !overflowed && gap > -1000 && gap < 1000
            && amountML == other.amountML
            && drinkType == other.drinkType
    }

    /// Every time a drink can have: Foundation's distant past to its distant future. Far
    /// inside what Int64 holds, so the difference of any two can't overflow.
    static let plausibleMilliseconds: ClosedRange<Int64> = -62_135_769_600_000...64_092_211_200_000
}

/// What Health holds for one kind of a drink's samples, kept on the synced drink
/// (`WaterEntry.healthWaterWritten`, `healthCaffeineWritten`) so every device can see it.
///
/// 1.8.1 queued an edited drink's samples in this device's own defaults, so an edit made
/// where Health sync was off was corrected only when sync was turned on there, never by
/// another device that already synced. With the record on the drink, a drink whose figures
/// no longer match what Health was given needs replacing, whichever device edited it, and
/// the device that owns the sample does it.
///
/// A string rather than several fields, like `Bottle.linkedTagIDs`: it is the one shape
/// CloudKit cannot get wrong, and a sample and the figures it was written with then always
/// change together. Format version 1, ten fields separated by `|`:
///
///     1 | state | sample UUID | sync identifier | sync version | ms since 1970 | amountML | drink type | owner | mark
///
/// Only the owner, the device that wrote the sample or claimed it, replaces it straight
/// away. Two
/// devices doing the same replacement at once would each delete and write, and whether
/// Health merges their two samples into one across iCloud has never been tested on two
/// devices. Any other device takes over only once a drink has been out of date for a week
/// (see `HealthPendingWork`), which covers an owner that is gone or has sync turned off.
struct HealthWrittenRecord: Equatable {
    enum State: String {
        /// Health holds this sample, written with these figures.
        case written = "w"
        /// Health holds nothing of this kind for the drink, as of these figures. What a
        /// replacement leaves when the edited drink no longer counts, so editing it back
        /// puts it back, even for a drink from before sync was turned on.
        case nothing = "n"
        /// The drink's sample is known to be out of date, with its figures unknown. Written
        /// only when the device-local queue 1.8.1 left behind is moved onto the drink.
        case stale = "s"
    }

    static let formatVersion = "1"

    var state: State
    /// The sample the record describes. Nil for `nothing`.
    var sampleUUID: String?
    /// The sync identifier the sample actually carries, or nil for one written without,
    /// by 1.8.1 or earlier, which can only be found by its UUID.
    var syncIdentifier: String?
    /// The sample's sync version, or 0 for one written without a sync identifier.
    var syncVersion: Int64
    /// Nil for `stale`.
    var figures: HealthFigures?
    /// The device that looks after this sample (`HealthInstall.id`), or nil for one written
    /// before 1.9 that no device has claimed.
    var owner: String?
    /// Set by a 1.9 edit made after this was written. A device acts on a marked record
    /// straight away, and on an unmarked change only after a while (see
    /// `HealthPendingWork`).
    var editedSince: Bool

    var encoded: String {
        [
            Self.formatVersion,
            state.rawValue,
            sampleUUID ?? "",
            syncIdentifier ?? "",
            String(syncVersion),
            figures.map { String($0.milliseconds) } ?? "",
            figures.map { String($0.amountML) } ?? "",
            figures?.drinkType ?? "",
            owner ?? "",
            editedSince ? "e" : "",
        ].joined(separator: "|")
    }

    init(
        state: State,
        sampleUUID: String?,
        syncIdentifier: String?,
        syncVersion: Int64,
        figures: HealthFigures?,
        owner: String?,
        editedSince: Bool = false
    ) {
        self.state = state
        self.sampleUUID = sampleUUID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.figures = figures
        self.owner = owner
        self.editedSince = editedSince
    }

    /// Nil for anything this version can't read in full: a later format, or a damaged
    /// string. Such a record is left alone rather than guessed at.
    init?(encoded: String) {
        let fields = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10,
              fields[0] == Self.formatVersion,
              let state = State(rawValue: fields[1]),
              let version = Int64(fields[4]), version >= 0,
              fields[9].isEmpty || fields[9] == "e" else { return nil }
        let sampleUUID = fields[2].isEmpty ? nil : fields[2]
        switch state {
        case .written, .stale:
            guard sampleUUID != nil else { return nil }
        case .nothing:
            guard sampleUUID == nil else { return nil }
        }
        let figures: HealthFigures?
        if fields[5].isEmpty && fields[6].isEmpty && fields[7].isEmpty {
            figures = nil
        } else if let milliseconds = Int64(fields[5]), HealthFigures.plausibleMilliseconds.contains(milliseconds),
                  let amount = Int(fields[6]), !fields[7].isEmpty {
            figures = HealthFigures(milliseconds: milliseconds, amountML: amount, drinkType: fields[7])
        } else {
            return nil
        }
        guard (state == .stale) == (figures == nil) else { return nil }
        self.init(
            state: state,
            sampleUUID: sampleUUID,
            syncIdentifier: fields[3].isEmpty ? nil : fields[3],
            syncVersion: version,
            figures: figures,
            owner: fields[8].isEmpty ? nil : fields[8],
            editedSince: fields[9] == "e"
        )
    }

    /// The version for the next sample written under a sync identifier. Distinct across
    /// devices in practice, and above the one it replaces: Health keeps the higher of two
    /// versions, lets an equal one replace, and silently drops a lower one.
    static func nextVersion(after previous: Int64, now: Date = Date()) -> Int64 {
        // A damaged record could carry the largest version there is, and going past it would
        // crash the pass on every launch.
        max(previous < .max ? previous + 1 : previous, HealthFigures.milliseconds(of: now))
    }
}

/// How a drink's record field reads.
enum HealthRecordReading: Equatable {
    /// No record: a sample written before 1.9, or no sample at all.
    case none
    /// Written by a later version, or damaged. Left alone, and so is Health.
    case foreign
    case record(HealthWrittenRecord)

    init(_ field: String?) {
        guard let field, !field.isEmpty else {
            self = .none
            return
        }
        if let record = HealthWrittenRecord(encoded: field) {
            self = .record(record)
        } else {
            self = .foreign
        }
    }

    var record: HealthWrittenRecord? {
        if case .record(let record) = self { return record }
        return nil
    }
}

/// What it takes to find one of a drink's samples in Health once the drink itself is gone.
/// Read before a delete: after it, so is the only record of which samples were the drink's.
struct HealthSampleReference: Equatable {
    let kind: HealthSampleKind
    let uuid: String?
    let syncIdentifiers: [String]

    /// Every sample a drink may have. Found by sync identifier as well as UUID, so a sample
    /// another device wrote before this device heard its UUID still goes.
    static func all(of entry: WaterEntry) -> [HealthSampleReference] {
        HealthSampleKind.allCases.compactMap { kind in
            let reference = HealthSampleReference(
                kind: kind,
                uuid: entry.healthSampleUUID(for: kind),
                syncIdentifiers: entry.healthSyncIdentifiers(for: kind)
            )
            return reference.uuid == nil && reference.syncIdentifiers.isEmpty ? nil : reference
        }
    }
}

/// The Health side of a drink, by kind. Kept out of `WaterEntry.swift`, which the widget
/// compiles and which must not need anything from Health.
extension WaterEntry {
    func healthSampleUUID(for kind: HealthSampleKind) -> String? {
        switch kind {
        case .water: return healthKitSampleUUID
        case .caffeine: return caffeineSampleUUID
        }
    }

    func setHealthSampleUUID(_ uuid: String?, for kind: HealthSampleKind) {
        switch kind {
        case .water: healthKitSampleUUID = uuid
        case .caffeine: caffeineSampleUUID = uuid
        }
    }

    func healthRecord(for kind: HealthSampleKind) -> HealthRecordReading {
        HealthRecordReading(healthRecordField(for: kind))
    }

    /// The record exactly as stored, for notes that must change whenever it does.
    func healthRecordField(for kind: HealthSampleKind) -> String? {
        switch kind {
        case .water: return healthWaterWritten
        case .caffeine: return healthCaffeineWritten
        }
    }

    func setHealthRecord(_ record: HealthWrittenRecord?, for kind: HealthSampleKind) {
        setHealthRecordField(record?.encoded, for: kind)
    }

    /// The record exactly as stored, for putting back what a failed save changed.
    func setHealthRecordField(_ field: String?, for kind: HealthSampleKind) {
        switch kind {
        case .water: healthWaterWritten = field
        case .caffeine: healthCaffeineWritten = field
        }
    }

    /// Whether Health has, or has had, anything of this drink's.
    var hasHealthSamplesOrRecords: Bool {
        healthKitSampleUUID != nil || caffeineSampleUUID != nil
            || healthWaterWritten != nil || healthCaffeineWritten != nil
    }

    /// Every sync identifier this drink's sample of one kind may carry: the one its record
    /// names, and the one its own Health identifier gives.
    func healthSyncIdentifiers(for kind: HealthSampleKind) -> [String] {
        var identifiers: [String] = []
        if let recorded = healthRecord(for: kind).record?.syncIdentifier {
            identifiers.append(recorded)
        }
        if let healthSyncID {
            let own = Self.healthSyncIdentifier(base: healthSyncID, kind: kind)
            if !identifiers.contains(own) { identifiers.append(own) }
        }
        return identifiers
    }

    static func healthSyncIdentifier(base: String, kind: HealthSampleKind) -> String {
        "\(base).\(kind.rawValue)"
    }

    /// Notes, before an edit is applied, that Health is now behind this drink.
    ///
    /// A sample 1.9 wrote already has a record of the figures it was written with, which the
    /// edit is about to change; marking it tells the sample's owner to act at once rather
    /// than wait a day on a change it can't place. A sample written earlier has no record,
    /// so one is made from the figures the drink has now, before the edit. A record nobody
    /// owns yet is claimed by `owner` for its kind: this device, when it may write that kind
    /// to Health and so will make the replacement itself, as 1.8.1 did. Touches only the
    /// synced drink, never Health, so it works the same with sync on or off.
    func noteHealthEdit(claimedBy owner: (HealthSampleKind) -> String?) {
        for kind in HealthSampleKind.allCases {
            let owner = owner(kind)
            let sampleID = healthSampleUUID(for: kind)
            switch healthRecord(for: kind) {
            case .foreign:
                continue
            case .record(var record) where !record.isVoid(currentUUID: sampleID):
                record.editedSince = true
                if record.owner == nil { record.owner = owner }
                setHealthRecord(record, for: kind)
            default:
                guard let sampleID else { continue }
                setHealthRecord(
                    HealthWrittenRecord(
                        state: .written,
                        sampleUUID: sampleID,
                        syncIdentifier: nil,
                        syncVersion: 0,
                        figures: HealthFigures(of: self),
                        owner: owner,
                        editedSince: true
                    ),
                    for: kind
                )
            }
        }
    }

    /// The same, with one claimant for both kinds.
    func noteHealthEdit(claimedBy owner: String?) {
        noteHealthEdit { _ in owner }
    }

    /// Takes back the mark an edit left, for each kind whose record now matches the drink
    /// again: edited back to what Health already has. A mark left behind would make a later
    /// change from a device still on 1.8.1 look like a 1.9 edit, and the owner would race
    /// that device instead of waiting the day for it.
    ///
    /// Only on a record this device owns, or that nobody owns. Another device may be
    /// replacing the sample at this moment, and this write merged over its new record would
    /// leave a record of the old sample that nothing ever acts on. Left alone, the owner
    /// sees the edit back as a change and puts Health right.
    func settleHealthEdit(on device: String?) {
        let current = HealthFigures(of: self)
        for kind in HealthSampleKind.allCases {
            guard case .record(var record) = healthRecord(for: kind),
                  record.editedSince,
                  record.owner == nil || (device != nil && record.owner == device),
                  record.state != .stale,
                  !record.isVoid(currentUUID: healthSampleUUID(for: kind)),
                  let written = record.figures,
                  written.matches(current) else { continue }
            record.editedSince = false
            setHealthRecord(record, for: kind)
        }
    }

    /// Notes that a sample 1.8.1 queued for replacement on this device is out of date, with
    /// the figures it was written with long gone. Claimed by `owner` as an edit is.
    func noteStaleHealthSample(_ sampleID: String, kind: HealthSampleKind, claimedBy owner: String?) {
        switch healthRecord(for: kind) {
        case .foreign:
            return
        case .record(var record) where !record.isVoid(currentUUID: healthSampleUUID(for: kind)):
            record.editedSince = true
            if record.owner == nil { record.owner = owner }
            setHealthRecord(record, for: kind)
        default:
            setHealthRecord(
                HealthWrittenRecord(state: .stale, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: nil, owner: owner),
                for: kind
            )
        }
    }
}

/// This device, as the records of what Health holds name it.
///
/// Kept in a keychain item that stays on this device. The app's defaults are restored from
/// a backup onto a new phone, and two devices with one name would both act as the owner of
/// the same samples. The vendor identifier changes when the app is deleted and installed
/// again, and the device would then wait a week to correct its own samples. A keychain item
/// marked this-device-only outlives a reinstall and never moves to another phone. Nil before
/// the first unlock after a restart, when this device simply owns nothing for a moment.
@MainActor
enum HealthInstall {
    private static let service = "com.jonathonbrown.HydroDrop.health"
    private static let account = "device"
    private static var known: String?

    static var id: String? {
        if let known { return known }
        let found = read() ?? create()
        known = found
        return found
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func create() -> String? {
        let id = UUID().uuidString
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return id
        case errSecDuplicateItem:
            // Read failed only for the moment, and there is one already.
            return read()
        default:
            return nil
        }
    }
}
