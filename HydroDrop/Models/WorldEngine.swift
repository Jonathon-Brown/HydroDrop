import Foundation

// The droplet's world: a pond that fills in over weeks. Everything here is worked out
// from the drinks already in the log, so someone opening this version for the first time
// finds a world that already reflects the days they have put in.

/// What has grown. Each stage adds one thing to the scene and nothing ever takes one
/// away. The raw value is the number of goal days that unlocks it, which is also what is
/// stored, so stages can be added later without disturbing anything already earned.
enum WorldStage: Int, CaseIterable, Identifiable, Comparable {
    case pond = 0
    case sprout = 3
    case reeds = 7
    case lilyPads = 14
    case flowers = 30
    case tree = 60
    case fireflies = 100
    case koi = 200
    case blossom = 365

    var id: Int { rawValue }
    var goalDays: Int { rawValue }

    static func < (lhs: WorldStage, rhs: WorldStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .pond: return "A quiet pond"
        case .sprout: return "A first sprout"
        case .reeds: return "Reeds by the water"
        case .lilyPads: return "Lily pads"
        case .flowers: return "Wildflowers"
        case .tree: return "A young tree"
        case .fireflies: return "Fireflies"
        case .koi: return "A koi in the pond"
        case .blossom: return "The tree in blossom"
        }
    }

    /// Said when it unlocks. About what arrived, never about what to do next.
    var blurb: String {
        switch self {
        case .pond: return "Every world starts with water."
        case .sprout: return "Something green has come up by the pond."
        case .reeds: return "Reeds have taken root at the water's edge."
        case .lilyPads: return "Lily pads have spread across the pond."
        case .flowers: return "Wildflowers have come up along the bank."
        case .tree: return "A young tree has grown beside the water."
        case .fireflies: return "Fireflies come out over the pond at night, and dragonflies by day."
        case .koi: return "A koi has made the pond its home."
        case .blossom: return "A whole year of days. The tree is in blossom."
        }
    }

    var icon: String {
        switch self {
        case .pond: return "drop.fill"
        case .sprout: return "leaf.fill"
        case .reeds: return "water.waves"
        case .lilyPads: return "circle.circle.fill"
        case .flowers: return "camera.macro"
        case .tree: return "tree.fill"
        case .fireflies: return "sparkles"
        case .koi: return "fish.fill"
        case .blossom: return "sun.max.fill"
        }
    }

    /// The furthest stage `goalDays` has reached.
    static func reached(by goalDays: Int) -> WorldStage {
        allCases.last { $0.goalDays <= goalDays } ?? .pond
    }

    var next: WorldStage? {
        Self.allCases.first { $0 > self }
    }

    /// The one to mark for a world that just grew, or nil. Only the furthest: a world
    /// restored from a long history can cross several at once, and that is one moment,
    /// not a queue of them. The bare pond is where everyone starts and is never news.
    static func newlyReached(goalDays: Int, alreadyCelebrated: Set<Int>) -> WorldStage? {
        let stage = reached(by: goalDays)
        guard stage != .pond, !alreadyCelebrated.contains(stage.goalDays) else { return nil }
        return stage
    }
}

/// How the world is doing, in words. Low vitality changes how the world looks and
/// never what is in it.
enum WorldVitality: String, CaseIterable {
    case thriving
    case healthy
    case thirsty
    case wilting

    init(_ value: Double) {
        switch value {
        case 0.8...: self = .thriving
        case 0.55...: self = .healthy
        case 0.3...: self = .thirsty
        default: self = .wilting
        }
    }

    var words: String {
        switch self {
        case .thriving: return "Thriving"
        case .healthy: return "Doing well"
        case .thirsty: return "A little thirsty"
        case .wilting: return "Wilting, but nothing is lost"
        }
    }
}

struct WorldState: Equatable {
    /// Lifetime goal days. Never goes down.
    var goalDays: Int
    /// 0 to 1.
    var vitality: Double

    var stage: WorldStage { WorldStage.reached(by: goalDays) }
    var mood: WorldVitality { WorldVitality(vitality) }

    /// How far from this stage to the next, 0 to 1. One when there is nothing further.
    var progressToNext: Double {
        guard let next = stage.next else { return 1 }
        let span = Double(next.goalDays - stage.goalDays)
        return span > 0 ? min(1, max(0, Double(goalDays - stage.goalDays) / span)) : 1
    }

    var daysToNext: Int? {
        stage.next.map { max(0, $0.goalDays - goalDays) }
    }

    /// The world, said out loud.
    var spokenDescription: String {
        var parts = ["Your droplet's world. \(stage.title). \(goalDays) goal \(goalDays == 1 ? "day" : "days") so far. \(mood.words)."]
        if let next = stage.next, let days = daysToNext {
            parts.append("\(next.title) in \(days) more \(days == 1 ? "day" : "days").")
        }
        return parts.joined(separator: " ")
    }

    static let empty = WorldState(goalDays: 0, vitality: WorldEngine.startingVitality)
}

enum WorldEngine {
    static let missedDayCost = 0.2
    static let goalDayGain = 0.34
    /// Where a world with no history starts: well, with room for a first goal day to
    /// visibly do it good.
    static let startingVitality = 0.6

    /// - Parameters:
    ///   - totalsByDay: hydrating mL per day, as `StreakCalculator.totalsByDay` groups it.
    ///   - recordedGoalDays: the most goal days this person has ever been known to have.
    ///     History is judged against today's goal, so raising the goal, or deleting old
    ///     drinks, could make the count come out lower than it once did. Growth never
    ///     decreases, so the larger of the two is the answer.
    static func state(
        totalsByDay: [String: Int],
        goalML: Int,
        frozenDayKeys: [String] = [],
        recordedGoalDays: Int = 0,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WorldState {
        guard goalML > 0 else {
            return WorldState(goalDays: max(0, recordedGoalDays), vitality: startingVitality)
        }
        let met = Set(totalsByDay.filter { $0.value >= goalML }.keys)
        let goalDays = max(met.count, recordedGoalDays)
        return WorldState(
            goalDays: goalDays,
            vitality: vitality(
                loggedDays: Set(totalsByDay.keys),
                metDays: met,
                frozen: Set(frozenDayKeys),
                now: now,
                calendar: calendar
            )
        )
    }

    /// Walks every day from the first drink ever logged to today.
    ///
    /// A goal day raises vitality and a missed day lowers it. A day a streak freeze was
    /// spent on is not a missed day and changes nothing. Today is only ever counted in
    /// its favour: met, it raises; not met yet, it is still in progress and costs nothing.
    static func vitality(
        loggedDays: Set<String>,
        metDays: Set<String>,
        frozen: Set<String>,
        now: Date,
        calendar: Calendar = .current
    ) -> Double {
        let today = DayKey.key(for: now, calendar: calendar)
        guard let first = loggedDays.min(), first <= today else { return startingVitality }

        var value = startingVitality
        var cursor: String? = first
        while let day = cursor, day <= today {
            if metDays.contains(day) {
                value = min(1, value + goalDayGain)
            } else if day != today, !frozen.contains(day) {
                value = max(0, value - missedDayCost)
            }
            cursor = DayKey.nextDayKey(after: day, calendar: calendar)
        }
        return value
    }
}

/// The light the scene is drawn in.
enum WorldTimeOfDay: String, CaseIterable {
    case dawn, day, dusk, night

    init(hour: Int) {
        switch hour {
        case 5..<8: self = .dawn
        case 8..<17: self = .day
        case 17..<20: self = .dusk
        default: self = .night
        }
    }

    init(date: Date, calendar: Calendar = .current) {
        #if DEBUG
        if let forced = WorldDebug.value(after: "-WorldTime").flatMap(WorldTimeOfDay.init(rawValue:)) {
            self = forced
            return
        }
        #endif
        self.init(hour: calendar.component(.hour, from: date))
    }

    var isDark: Bool { self == .night }
}

/// The sky, roughly. Only ever what the hot-day feature already fetched for its own
/// reasons: the world never asks for a location or a forecast of its own.
enum WorldWeather: String, CaseIterable {
    case clear, cloudy, rain, snow

    /// How long a fetched sky is believed. Weather moves on, and a morning's rain drawn
    /// over a sunny afternoon is worse than no weather at all.
    static let freshness: TimeInterval = 3 * 60 * 60

    private static let conditionKey = "world.weather.condition"
    private static let fetchedAtKey = "world.weather.fetchedAt"

    /// Called by the hot-day feature with what it just learned.
    static func remember(_ weather: WorldWeather, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(weather.rawValue, forKey: conditionKey)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: fetchedAtKey)
    }

    /// The sky to draw, or nil when the feature is off or what is known is too old.
    static func current(isFeatureActive: Bool, now: Date = Date(), in defaults: UserDefaults = .standard) -> WorldWeather? {
        #if DEBUG
        if defaults === UserDefaults.standard,
           let forced = WorldDebug.value(after: "-WorldWeather").flatMap(WorldWeather.init(rawValue:)) {
            return forced
        }
        #endif
        guard isFeatureActive,
              let raw = defaults.string(forKey: conditionKey),
              let weather = WorldWeather(rawValue: raw),
              defaults.object(forKey: fetchedAtKey) != nil else { return nil }
        let age = now.timeIntervalSinceReferenceDate - defaults.double(forKey: fetchedAtKey)
        return (0...freshness).contains(age) ? weather : nil
    }
}

/// Things that can be put in the world. They are decoration and nothing else: none of
/// them is earned, none is lost, and none says anything about how anyone is doing.
enum WorldDecoration: String, CaseIterable, Identifiable {
    case lantern
    case steppingStones
    case paperBoat
    case rubberDuck
    case mushrooms
    case birdhouse
    case bridge
    case balloon
    case bunting

    var id: String { rawValue }

    /// Two are free. The rest are part of HydroDrop+.
    var requiresPlus: Bool {
        switch self {
        case .lantern, .steppingStones: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .lantern: return "Lantern"
        case .steppingStones: return "Stepping stones"
        case .paperBoat: return "Paper boat"
        case .rubberDuck: return "Rubber duck"
        case .mushrooms: return "Mushrooms"
        case .birdhouse: return "Birdhouse"
        case .bridge: return "Little bridge"
        case .balloon: return "Balloon"
        case .bunting: return "Bunting"
        }
    }

    var icon: String {
        switch self {
        case .lantern: return "lamp.table.fill"
        case .steppingStones: return "circle.hexagongrid.fill"
        case .paperBoat: return "sailboat.fill"
        case .rubberDuck: return "bird.fill"
        case .mushrooms: return "umbrella.fill"
        case .birdhouse: return "house.fill"
        case .bridge: return "road.lanes.curved.right"
        case .balloon: return "balloon.fill"
        case .bunting: return "flag.2.crossed.fill"
        }
    }

    /// What is actually drawn: the chosen ones, less any the entitlement does not cover.
    /// Derived where it is used, like the mascot skin, so choices survive a lapse and
    /// come back with the subscription.
    static func active(from rawValues: [String], isPlusActive: Bool) -> [WorldDecoration] {
        allCases.filter { rawValues.contains($0.rawValue) && (isPlusActive || !$0.requiresPlus) }
    }
}

#if DEBUG
/// Launch arguments for looking at a world no simulator has the history for:
/// `-WorldPreview <goal days> <vitality percent>`, `-WorldTime dawn|day|dusk|night`,
/// `-WorldWeather clear|cloudy|rain|snow`, `-WorldAllDecorations`. Compiled out of Release.
enum WorldDebug {
    static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static var state: WorldState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-WorldPreview"),
              arguments.indices.contains(index + 2),
              let days = Int(arguments[index + 1]),
              let percent = Double(arguments[index + 2]) else { return nil }
        return WorldState(goalDays: days, vitality: min(1, max(0, percent / 100)))
    }

    static var showsAllDecorations: Bool {
        ProcessInfo.processInfo.arguments.contains("-WorldAllDecorations")
    }
}
#endif

