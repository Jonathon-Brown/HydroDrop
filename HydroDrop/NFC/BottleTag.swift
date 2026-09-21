import Foundation

/// What is written on a bottle's NFC sticker, and how it is read back.
///
/// The sticker carries one web address: `https://hydrodrop.us/tap?b=<bottle id>`. A web
/// address rather than a custom scheme because iOS only hands a tag read in the
/// background to an app through a universal link, and because a phone without
/// HydroDrop then opens a page that says what the sticker is for instead of failing.
enum BottleTag {
    static let host = "hydrodrop.us"
    static let queryName = "b"
    /// What is written to a tag, and the page the website serves for it. Both reach the
    /// app, because the association file claims everything under `/tap`.
    private static let acceptedPaths: Set<String> = ["/tap", "/tap/", "/tap.html"]

    /// The address to write on the sticker for a bottle.
    static func url(for bottleID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/tap"
        components.queryItems = [URLQueryItem(name: queryName, value: bottleID.uuidString)]
        // Every piece above is a constant or a UUID, so this cannot fail.
        return components.url!
    }

    /// The tag id in a tapped or scanned address, or nil if it is not one of ours.
    ///
    /// Strict on purpose. A sticker can be written by anyone with a phone, so anything
    /// that is not exactly our address over HTTPS is treated as someone else's tag.
    static func tagID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              acceptedPaths.contains(components.path.lowercased()),
              let value = components.queryItems?.first(where: { $0.name == queryName })?.value else {
            return nil
        }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespaces))
    }

    /// The bottle a tag means, whether it is the bottle's own tag or one linked later.
    static func bottle(for tagID: UUID, in bottles: [Bottle]) -> Bottle? {
        bottles.first { $0.id == tagID } ?? bottles.first { $0.allTagIDs.contains(tagID) }
    }
}

/// Stops one tap from logging a bottle twice.
///
/// A phone held against a sticker can read it more than once, and the background read
/// and the in-app scanner can both fire for the same touch. Keyed by bottle rather than
/// by tag, so two stickers on the same bottle still count as the same drink.
struct BottleTapDebouncer: Equatable {
    /// How long after a logged tap the same bottle is ignored.
    static let window: TimeInterval = 30

    private(set) var lastAccepted: [UUID: Date] = [:]

    init(lastAccepted: [UUID: Date] = [:]) {
        self.lastAccepted = lastAccepted
    }

    /// Whether a tap on `bottleID` at `now` should log. Accepting it starts the window;
    /// an ignored tap does not extend it, so a phone left resting on the sticker cannot
    /// lock the bottle out forever.
    mutating func shouldAccept(_ bottleID: UUID, at now: Date) -> Bool {
        if let last = lastAccepted[bottleID] {
            let elapsed = now.timeIntervalSince(last)
            // A clock that has gone backwards is not a repeat.
            if elapsed >= 0, elapsed < Self.window { return false }
        }
        lastAccepted[bottleID] = now
        // Nothing older than the window can matter again.
        lastAccepted = lastAccepted.filter { now.timeIntervalSince($0.value) < Self.window }
        return true
    }

    /// Forgets a bottle's last tap, so taking a drink back lets it be logged again.
    mutating func forget(_ bottleID: UUID) {
        lastAccepted[bottleID] = nil
    }
}

extension BottleTapDebouncer {
    private static let defaultsKey = "bottleTag.lastTaps"

    /// Kept across launches: the second read of one touch can be the one that launches
    /// the app, and a debouncer that starts empty would let it through.
    static func load(from defaults: UserDefaults = .standard) -> BottleTapDebouncer {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        var taps: [UUID: Date] = [:]
        for (key, value) in stored {
            if let id = UUID(uuidString: key) {
                taps[id] = Date(timeIntervalSinceReferenceDate: value)
            }
        }
        return BottleTapDebouncer(lastAccepted: taps)
    }

    func save(to defaults: UserDefaults = .standard) {
        var stored: [String: Double] = [:]
        for (id, date) in lastAccepted {
            stored[id.uuidString] = date.timeIntervalSinceReferenceDate
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}

/// How many bottles someone can have.
enum BottleLimit {
    /// One bottle is free. More is part of HydroDrop+.
    static let freeBottleCount = 1

    static func canAddBottle(existingCount: Int, isSubscribed: Bool) -> Bool {
        isSubscribed || existingCount < freeBottleCount
    }
}
