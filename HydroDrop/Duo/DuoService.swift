import CloudKit

/// What went wrong, in the terms the Duo screen can say something useful about.
enum DuoError: Error, Equatable {
    /// A zone that is not a duo's was about to be touched. Never expected; refused.
    case notADuoZone
    /// The zone or the share is gone: the other person left, or the duo was deleted.
    case ended
    /// iCloud answered with something this version does not understand.
    case unreadable
}

/// What to do about a failed write.
enum DuoRetry {
    enum Verdict: Equatable {
        case retry(after: TimeInterval)
        case ended
        case fail
    }

    /// Used when iCloud asks for a retry without saying when, and for a dropped network.
    static let fallbackDelay: TimeInterval = 30
    /// After this many tries in a row the write waits for the app to come forward again.
    static let maximumAttempts = 3

    static func verdict(for error: Error) -> Verdict {
        if let duoError = error as? DuoError { return duoError == .ended ? .ended : .fail }
        guard let error = error as? CKError else { return .fail }
        switch error.code {
        case .zoneBusy, .requestRateLimited, .serviceUnavailable:
            return .retry(after: error.retryAfterSeconds ?? fallbackDelay)
        case .networkUnavailable, .networkFailure:
            return .retry(after: error.retryAfterSeconds ?? fallbackDelay)
        case .serverRecordChanged:
            // Someone else wrote first. The write names only its own fields, so sending
            // it again is the whole of the fix.
            return .retry(after: error.retryAfterSeconds ?? 0)
        case .zoneNotFound, .userDeletedZone:
            return .ended
        case .partialFailure:
            let verdicts = (error.partialErrorsByItemID ?? [:]).values.map(verdict(for:))
            if verdicts.contains(.ended) { return .ended }
            let delays = verdicts.compactMap { verdict -> TimeInterval? in
                if case .retry(let after) = verdict { return after }
                return nil
            }
            return delays.max().map { .retry(after: $0) } ?? .fail
        default:
            return .fail
        }
    }
}

/// What a fetch brought back.
struct DuoChanges {
    struct Identity {
        var createdAt: Date?
        var ownerDisplayName: String
        var partnerDisplayName: String
        var ownerSkin: String
        var partnerSkin: String
    }

    /// True when there was no change token, so this is everything in the zone rather
    /// than what is new, and replaces what was cached rather than adding to it.
    var isEverything: Bool
    var identity: Identity?
    var statuses: [DuoDayStatus] = []
    var deletedStatusNames: [String] = []
    var changeToken: Data?
}

/// The raw CloudKit layer under Duo Streaks.
///
/// SwiftData cannot mirror a shared database, so a duo is kept here instead, by hand, in
/// the same iCloud container: one zone per duo in the inviter's private database, shared
/// as a whole with one other person. Nothing here reads or writes any zone whose name
/// does not start with `Duo-`. The zone SwiftData mirrors the drink log into is not
/// this layer's business and is never touched.
///
/// Only two record types exist. `Duo` holds two first names and two skins. `DayStatus`
/// holds, for one person and one day, whether the goal was met and progress rounded down
/// to a quarter. No drink, amount or time of day is ever written.
actor DuoService {
    static let shared = DuoService()

    private enum RecordType {
        static let duo = "Duo"
        static let dayStatus = "DayStatus"
    }

    private enum Field {
        static let createdAt = "createdAt"
        static let ownerDisplayName = "ownerDisplayName"
        static let partnerDisplayName = "partnerDisplayName"
        static let ownerSkin = "ownerSkin"
        static let partnerSkin = "partnerSkin"
        static let role = "role"
        static let day = "day"
        static let goalMet = "goalMet"
        static let progressBucket = "progressBucket"
        static let updatedAt = "updatedAt"
    }

    /// The container named in the entitlements, which is also the one SwiftData uses.
    /// Made on first use: asking for it is the first thing that needs iCloud at all.
    nonisolated var container: CKContainer { CKContainer.default() }

    // MARK: - Where a duo lives

    private func database(for role: DuoRole) -> CKDatabase {
        role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for duo: DuoState) throws -> CKRecordZone.ID {
        guard DuoRecordName.duoID(fromZoneName: duo.zoneName) != nil else { throw DuoError.notADuoZone }
        let owner = duo.myRole == .owner ? CKCurrentUserDefaultName : duo.zoneOwnerName
        return CKRecordZone.ID(zoneName: duo.zoneName, ownerName: owner)
    }

    private func shareID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    }

    // MARK: - Account

    func accountStatus() async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            Diagnostics.log("could not read the iCloud account status: \(error)")
            return .couldNotDetermine
        }
    }

    // MARK: - Starting a duo

    /// Makes the zone, the `Duo` record and the share, in the inviter's private database.
    func createDuo(id: UUID, ownerName: String, ownerSkin: String, now: Date) async throws -> (DuoState, CKShare) {
        var state = DuoState(
            id: id,
            zoneName: DuoRecordName.zoneName(for: id),
            zoneOwnerName: CKCurrentUserDefaultName,
            myRole: .owner,
            createdAt: now,
            ownerDisplayName: ownerName,
            partnerDisplayName: "",
            ownerSkin: ownerSkin,
            partnerSkin: "",
            statuses: [],
            shareURL: nil,
            partnerHasJoined: false,
            endedAt: nil
        )
        let zoneID = try zoneID(for: state)
        let database = database(for: .owner)

        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        if case .failure(let error)? = zones.saveResults[zoneID] { throw error }

        let record = CKRecord(recordType: RecordType.duo, recordID: CKRecord.ID(recordName: DuoRecordName.duo, zoneID: zoneID))
        record[Field.createdAt] = now
        record[Field.ownerDisplayName] = ownerName
        record[Field.partnerDisplayName] = ""
        record[Field.ownerSkin] = ownerSkin
        record[Field.partnerSkin] = ""

        let share = Self.newShare(for: zoneID)

        let saved = try await save([record, share], in: database)
        let savedShare = saved.compactMap { $0 as? CKShare }.first ?? share
        state.shareURL = savedShare.url
        return (state, savedShare)
    }

    /// The share as it stands, for sending the invite again.
    ///
    /// Apple's invite sheet has a Stop Sharing button of its own, which deletes the
    /// share and leaves the zone. For the owner, a missing share is therefore made
    /// again rather than reported, so the invite can always be sent.
    ///
    /// Only when asked to, which is only when the invite is being sent. Looking in on a
    /// share never brings one back: an owner who stopped sharing meant it.
    func share(for duo: DuoState, makingAgainIfMissing: Bool) async throws -> CKShare {
        let zoneID = try zoneID(for: duo)
        let database = database(for: duo.myRole)
        do {
            guard let share = try await database.record(for: shareID(in: zoneID)) as? CKShare else {
                throw DuoError.unreadable
            }
            return share
        } catch let error as CKError where error.code == .unknownItem && duo.myRole == .owner && makingAgainIfMissing {
            let saved = try await save([Self.newShare(for: zoneID)], in: database)
            guard let share = saved.compactMap({ $0 as? CKShare }).first else { throw DuoError.unreadable }
            return share
        }
    }

    private static func newShare(for zoneID: CKRecordZone.ID) -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Duo streak on HydroDrop"
        // Only people who are invited. There is no link that lets just anyone in.
        share.publicPermission = .none
        return share
    }

    /// Owner only. Whether a partner is in the share, after making sure there is at most
    /// one: the first to accept stays, and anyone else, invited or joined, is removed.
    func settlePartner(in duo: DuoState) async throws -> Bool {
        let share: CKShare
        do {
            share = try await self.share(for: duo, makingAgainIfMissing: false)
        } catch let error as CKError where error.code == .unknownItem {
            // No share, so nobody is in it.
            return false
        }
        let seats = share.participants.enumerated().map { index, participant in
            DuoParticipants.Participant(
                id: String(index),
                isOwner: participant.role == .owner,
                hasAccepted: participant.acceptanceStatus == .accepted
            )
        }
        let extras = DuoParticipants.toRemove(from: seats, keeping: nil)
        if !extras.isEmpty {
            let leaving = share.participants.enumerated().filter { extras.contains(String($0.offset)) }.map(\.element)
            leaving.forEach(share.removeParticipant)
            _ = try await save([share], in: database(for: .owner))
            Diagnostics.log("a duo is two people: removed \(leaving.count) extra from the share")
        }
        return seats.contains { !$0.isOwner && $0.hasAccepted }
    }

    // MARK: - Joining a duo

    /// The zone a share invites into, if it is a duo's.
    nonisolated func duoZone(of metadata: CKShare.Metadata) -> (id: UUID, zoneID: CKRecordZone.ID)? {
        let zoneID = metadata.share.recordID.zoneID
        guard let id = DuoRecordName.duoID(fromZoneName: zoneID.zoneName) else { return nil }
        return (id, zoneID)
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            var firstError: Error?
            operation.perShareResultBlock = { _, result in
                if case .failure(let error) = result, firstError == nil { firstError = error }
            }
            operation.acceptSharesResultBlock = { result in
                switch (result, firstError) {
                case (_, let error?): continuation.resume(throwing: error)
                case (.failure(let error), _): continuation.resume(throwing: error)
                case (.success, nil): continuation.resume()
                }
            }
            operation.qualityOfService = .userInitiated
            container.add(operation)
        }
    }

    // MARK: - Writing

    /// Upserts day statuses. Each record is named after whose day it is, so a repeat is
    /// the same record again, and only the fields set here are sent.
    func write(_ statuses: [DuoDayStatus], in duo: DuoState) async throws {
        guard !statuses.isEmpty else { return }
        let zoneID = try zoneID(for: duo)
        let records = statuses.map { status -> CKRecord in
            let record = CKRecord(
                recordType: RecordType.dayStatus,
                recordID: CKRecord.ID(recordName: status.recordName, zoneID: zoneID)
            )
            record[Field.role] = status.role.rawValue
            record[Field.day] = status.day
            record[Field.goalMet] = status.goalMet
            record[Field.progressBucket] = status.progressBucket
            record[Field.updatedAt] = status.updatedAt
            return record
        }
        _ = try await save(records, in: database(for: duo.myRole))
    }

    /// Writes this person's own first name and skin, and nothing about the other side.
    func writeIdentity(name: String, skin: String, in duo: DuoState) async throws {
        let zoneID = try zoneID(for: duo)
        let record = CKRecord(recordType: RecordType.duo, recordID: CKRecord.ID(recordName: DuoRecordName.duo, zoneID: zoneID))
        record[duo.myRole == .owner ? Field.ownerDisplayName : Field.partnerDisplayName] = name
        record[duo.myRole == .owner ? Field.ownerSkin : Field.partnerSkin] = skin
        _ = try await save([record], in: database(for: duo.myRole))
    }

    /// `.changedKeys` sends only the fields that were set and does not compare change
    /// tags, which is what makes writing a freshly built record an upsert.
    private func save(_ records: [CKRecord], in database: CKDatabase) async throws -> [CKRecord] {
        let results = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        return try results.saveResults.values.map { try $0.get() }
    }

    // MARK: - Reading

    /// Everything that changed in the duo's zone since the token it was last read with.
    func fetchChanges(in duo: DuoState) async throws -> DuoChanges {
        do {
            return try await fetchChanges(in: duo, since: duo.changeToken)
        } catch let error as CKError where error.code == .changeTokenExpired {
            Diagnostics.log("a duo's change token expired; reading the whole zone again")
            return try await fetchChanges(in: duo, since: nil)
        }
    }

    private func fetchChanges(in duo: DuoState, since tokenData: Data?) async throws -> DuoChanges {
        let zoneID = try zoneID(for: duo)
        let token = tokenData.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let database = database(for: duo.myRole)

        final class Collected: @unchecked Sendable {
            var records: [CKRecord] = []
            var deleted: [CKRecord.ID] = []
            var token: CKServerChangeToken?
            var zoneError: Error?
        }
        let collected = Collected()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = token
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            // Every page, not just the first: the zone's result arrives once, after the
            // last of them, and its token is the one that is safe to keep.
            operation.fetchAllChanges = true
            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { collected.records.append(record) }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                collected.deleted.append(recordID)
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let done): collected.token = done.serverChangeToken
                case .failure(let error): collected.zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch (result, collected.zoneError) {
                case (_, let error?): continuation.resume(throwing: error)
                case (.failure(let error), _): continuation.resume(throwing: error)
                case (.success, nil): continuation.resume()
                }
            }
            operation.qualityOfService = .userInitiated
            database.add(operation)
        }

        var changes = DuoChanges(isEverything: token == nil)
        changes.changeToken = collected.token.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        for record in collected.records {
            switch record.recordType {
            case RecordType.duo:
                changes.identity = DuoChanges.Identity(
                    createdAt: record[Field.createdAt] as? Date,
                    ownerDisplayName: DuoState.cleanedName(record[Field.ownerDisplayName] as? String ?? ""),
                    partnerDisplayName: DuoState.cleanedName(record[Field.partnerDisplayName] as? String ?? ""),
                    ownerSkin: record[Field.ownerSkin] as? String ?? "",
                    partnerSkin: record[Field.partnerSkin] as? String ?? ""
                )
            case RecordType.dayStatus:
                if let status = Self.status(from: record) { changes.statuses.append(status) }
            default:
                // The share itself, and anything a newer version of the app keeps here.
                continue
            }
        }
        changes.deletedStatusNames = collected.deleted.map(\.recordName)
        return changes
    }

    /// Reads a status, trusting the record's name over its fields: the name is what
    /// makes it one person's one day, and a record whose fields disagree with its name
    /// is ignored rather than believed.
    private static func status(from record: CKRecord) -> DuoDayStatus? {
        guard let named = DuoRecordName.parseDayStatus(record.recordID.recordName) else { return nil }
        if let role = record[Field.role] as? String, role != named.role.rawValue { return nil }
        if let day = record[Field.day] as? String, day != named.day { return nil }
        let goalMet = (record[Field.goalMet] as? NSNumber)?.boolValue ?? false
        let raw = (record[Field.progressBucket] as? NSNumber)?.intValue ?? 0
        // Snapped down to a bucket this version knows, whatever was written.
        let bucket = DuoProgress.buckets.last { $0 <= raw } ?? 0
        return DuoDayStatus(
            role: named.role,
            day: named.day,
            goalMet: goalMet,
            progressBucket: goalMet ? 100 : min(bucket, 75),
            updatedAt: record[Field.updatedAt] as? Date ?? record.modificationDate ?? .distantPast
        )
    }

    // MARK: - Leaving

    /// The owner leaving deletes the zone and everything in it. A partner leaving takes
    /// themselves out of the share, which is done by deleting their copy of it. Either
    /// way, a duo that is already gone counts as left.
    func leave(_ duo: DuoState) async throws {
        let zoneID = try zoneID(for: duo)
        do {
            switch duo.myRole {
            case .owner:
                let result = try await database(for: .owner).modifyRecordZones(saving: [], deleting: [zoneID])
                if case .failure(let error)? = result.deleteResults[zoneID] { throw error }
            case .partner:
                let shareID = shareID(in: zoneID)
                let result = try await database(for: .partner).modifyRecords(saving: [], deleting: [shareID])
                if case .failure(let error)? = result.deleteResults[shareID] { throw error }
            }
        } catch let error as CKError where [.zoneNotFound, .userDeletedZone, .unknownItem].contains(error.code) {
            return
        }
    }
}
