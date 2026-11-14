#if DUO_V2 && DEBUG
import Foundation

extension DuoStore {
    /// A store of sample duos for looking at the card and the screen with no server, which is
    /// every simulator run with `-DuoPreview`, and for a view's tests. Compiled out of Release.
    static func makePreview(duos: [DuoState]? = nil, cache: DuoCache? = nil) -> DuoStore {
        let defaults = UserDefaults(suiteName: "DuoPreview.\(UUID().uuidString)") ?? .standard
        let store = DuoStore(cache: cache ?? DuoCache(defaults: defaults), usesServer: false, reloadWidget: {})
        store.replaceAll(with: duos ?? previewDuos())
        store.availability = .available
        return store
    }

    static func previewDuos(now: Date = Date()) -> [DuoState] {
        let calendar = Calendar.current
        func day(_ offset: Int) -> String { DayKey.key(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now) }
        var statuses: [DuoDayStatus] = []
        for offset in 1...4 {
            for role in DuoRole.allCases {
                statuses.append(DuoDayStatus(role: role, day: day(offset), goalMet: true, progressBucket: 100, updatedAt: now))
            }
        }
        statuses.append(DuoDayStatus(role: .partner, day: day(0), goalMet: false, progressBucket: 50, updatedAt: now))

        func duo(_ partner: String, skin: String, statuses: [DuoDayStatus], joined: Bool, ended: Bool = false) -> DuoState {
            DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jonathon", partnerDisplayName: partner,
                     ownerSkin: "classic", partnerSkin: skin, statuses: statuses, partnerHasJoined: joined,
                     endedAt: ended ? now : nil, joinedAt: joined ? now : nil, endedBy: ended ? .partner : nil, syncedOnce: true)
        }
        var sam = duo("Sam", skin: "forest", statuses: statuses, joined: true)
        sam.nudges = [DuoNudge(id: "nudge-\(UUID().uuidString)", fromRole: .partner, presetID: DuoNudgePreset.sipWithMe.rawValue,
                               createdAt: now.addingTimeInterval(-40 * 60))]
        var waiting = duo("", skin: "", statuses: [], joined: false)
        waiting.invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: now.addingTimeInterval(40 * 3600))
        return [sam, waiting, duo("Alex", skin: "grape", statuses: [], joined: true, ended: true)]
    }
}

// MARK: - Named scenarios

extension DuoStore {
    /// What `-DuoPreview <name>` understands. The plain flag is `sample`. Every one draws from
    /// a store that talks to nobody, so a screen can be looked at, photographed and tested in
    /// each state it has without a server, and the integration pass's UI test launches the app
    /// with these. Compiled out of Release.
    static let previewScenarioNames = [
        "sample", "empty", "waiting", "justjoined", "silent", "streak100", "demo", "ended", "endedall", "full",
        "maintenance", "upgrade", "disconnected", "banned", "restore", "newdevice",
    ]

    static func makePreview(scenario: String, now: Date = Date()) -> DuoStore {
        func store(_ duos: [DuoState], _ availability: DuoAvailability = .available) -> DuoStore {
            let made = makePreview(duos: duos)
            made.availability = availability
            return made
        }
        switch scenario {
        case "empty": return store([])
        case "waiting": return store([previewDuo(partner: "", joined: false, now: now, invite: true)])
        case "justjoined": return store([previewDuo(partner: "Sam", joined: true, now: now, metDays: 0, joinedHoursAgo: 2)])
        case "silent":
            let lastWrite = DayKey.key(for: Calendar.current.date(byAdding: .day, value: -5, to: now) ?? now)
            return store([previewDuo(partner: "Sam", joined: true, now: now, metDays: 0, partnerLastWriteDay: lastWrite)])
        case "streak100": return store([previewDuo(partner: "Sam", joined: true, now: now, metDays: 101)])
        case "demo": return store([previewDuo(partner: "Sam", joined: true, now: now, metDays: 3, demo: true)])
        case "ended": return store([previewDuo(partner: "Alex", joined: true, now: now, metDays: 4, endedBy: .partner)])
        case "endedall":
            let reasons: [(String, DuoEndedBy)] = [("Alex", .partner), ("Blake", .owner), ("Casey", .partnerDeleted), ("Drew", .ownerDeleted),
                                                   ("Eli", .inactive), ("Sam", .demoExpired), ("Finn", .unknown)]
            return store(reasons.map { previewDuo(partner: $0.0, joined: true, now: now, metDays: 2, endedBy: $0.1) })
        case "full":
            // Five live duos: as many as HydroDrop+ allows, so the "as many as there can be" line shows.
            let names = ["Sam", "Alex", "Blake", "Casey", "Drew"]
            return store(names.map { previewDuo(partner: $0, joined: true, now: now, metDays: 3) })
        case "maintenance": return store(previewDuos(now: now), .maintenance)
        case "upgrade": return store(previewDuos(now: now), .upgradeRequired)
        case "disconnected": return store(previewDuos(now: now), .disconnected)
        case "banned": return store(previewDuos(now: now), .banned)
        case "restore": return store([], .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jonathon")))
        case "newdevice":
            let made = store(previewDuos(now: now))
            made.newDeviceNotice = true
            return made
        default: return makePreview()
        }
    }

    /// One sample duo, with me as its owner. `metDays` is how many days back both of us met our
    /// goal, ending yesterday.
    static func previewDuo(partner: String, joined: Bool, now: Date, metDays: Int = 4, endedBy: DuoEndedBy? = nil,
                           invite: Bool = false, demo: Bool = false, joinedHoursAgo: Double? = nil,
                           partnerLastWriteDay: String? = nil) -> DuoState {
        let calendar = Calendar.current
        func day(_ offset: Int) -> String { DayKey.key(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now) }
        var statuses: [DuoDayStatus] = []
        if metDays > 0 {
            for offset in 1...metDays {
                for role in DuoRole.allCases {
                    statuses.append(DuoDayStatus(role: role, day: day(offset), goalMet: true, progressBucket: 100, updatedAt: now))
                }
            }
        }
        var duo = DuoState(
            id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jonathon", partnerDisplayName: partner,
            ownerSkin: "classic", partnerSkin: joined ? "forest" : "", statuses: statuses, partnerHasJoined: joined,
            endedAt: endedBy == nil ? nil : now, joinedAt: joined ? now.addingTimeInterval(-(joinedHoursAgo ?? 72) * 3600) : nil,
            endedBy: endedBy, partnerLastWriteDay: partnerLastWriteDay, partnerIsDemo: demo, syncedOnce: true
        )
        if invite {
            duo.invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: now.addingTimeInterval(40 * 3600))
        }
        return duo
    }
}
#endif
