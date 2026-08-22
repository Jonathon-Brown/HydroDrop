import Foundation
import WatchConnectivity

/// Bridges the Watch app to the iPhone over WatchConnectivity. The iPhone
/// remains the source of truth for logged entries; this class sends
/// "log a drink" taps to it (queued, delivered even while unreachable) and
/// mirrors back the today total/goal it reports.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var todayTotalML: Int
    @Published var dailyGoalML: Int
    @Published var measurementSystem: MeasurementSystem

    /// The day the cached total belongs to. Stored as a day key rather than an instant,
    /// so "is this still today?" survives the watch and phone disagreeing about when
    /// midnight was.
    private var totalDayKey: String

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let todayTotalML = "watch.todayTotalML"
        static let todayTotalDayKey = "watch.todayTotalDayKey"
        static let legacyTodayTotalDate = "watch.todayTotalDate"
        static let dailyGoalML = "watch.dailyGoalML"
        static let measurementSystem = "watch.measurementSystem"
        static let outbox = "watch.pendingDrinks"
    }

    private override init() {
        let today = DayKey.key(for: Date())
        let storedDayKey = defaults.string(forKey: Keys.todayTotalDayKey)
            ?? (defaults.object(forKey: Keys.legacyTodayTotalDate) as? Date).map { DayKey.key(for: $0) }
        let staleTotal = storedDayKey != today
        todayTotalML = staleTotal ? 0 : (defaults.object(forKey: Keys.todayTotalML) as? Int ?? 0)
        totalDayKey = today
        dailyGoalML = defaults.object(forKey: Keys.dailyGoalML) as? Int ?? 2000
        if let raw = defaults.string(forKey: Keys.measurementSystem), let saved = MeasurementSystem(rawValue: raw) {
            measurementSystem = saved
        } else {
            measurementSystem = .deviceDefault
        }
        super.init()
        if staleTotal { persist() }
    }

    func activate() {
        resetTotalIfNewDay()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Optimistically applies the drink locally, then queues it for reliable delivery to the phone.
    func logDrink(amountML: Int) {
        resetTotalIfNewDay()
        todayTotalML += amountML
        persist()

        send(DrinkPayload(amountML: amountML, timestamp: Date(), id: UUID().uuidString))
    }

    /// A drink on its way to the phone.
    private struct DrinkPayload {
        let amountML: Int
        let timestamp: Date
        let id: String

        var userInfo: [String: Any] {
            ["type": "logDrink", "amountML": amountML, "timestamp": timestamp, "id": id]
        }

        var stored: [String: Any] {
            ["amountML": amountML, "timestamp": timestamp, "id": id]
        }

        init(amountML: Int, timestamp: Date, id: String) {
            self.amountML = amountML
            self.timestamp = timestamp
            self.id = id
        }

        init?(stored: [String: Any]) {
            guard let amountML = stored["amountML"] as? Int,
                  let timestamp = stored["timestamp"] as? Date,
                  let id = stored["id"] as? String else { return nil }
            self.init(amountML: amountML, timestamp: timestamp, id: id)
        }
    }

    /// `transferUserInfo` queues for us once the session is activated, but not before it
    /// is — and activation is asynchronous, so a tap in the first moments after launch
    /// used to increment the local total and go no further, losing the drink for good.
    /// Anything sent too early waits here instead and goes out on activation.
    private func send(_ payload: DrinkPayload) {
        guard WCSession.default.activationState == .activated else {
            var outbox = defaults.array(forKey: Keys.outbox) as? [[String: Any]] ?? []
            outbox.append(payload.stored)
            defaults.set(outbox, forKey: Keys.outbox)
            return
        }
        WCSession.default.transferUserInfo(payload.userInfo)
    }

    /// Sends anything that was logged before the session finished activating. The phone
    /// discards duplicates by id, so a flush that overlaps a redelivery is harmless.
    fileprivate func flushOutbox() {
        guard WCSession.default.activationState == .activated else { return }
        let stored = defaults.array(forKey: Keys.outbox) as? [[String: Any]] ?? []
        guard !stored.isEmpty else { return }
        defaults.removeObject(forKey: Keys.outbox)
        for entry in stored.compactMap(DrinkPayload.init(stored:)) {
            WCSession.default.transferUserInfo(entry.userInfo)
        }
    }

    /// The cached total is only meaningful for the calendar day it was last touched on — a watch
    /// that logs a drink before the phone has resynced today's context must not add onto yesterday's total.
    private func resetTotalIfNewDay() {
        let today = DayKey.key(for: Date())
        guard totalDayKey != today else { return }
        todayTotalML = 0
        totalDayKey = today
        persist()
    }

    private func persist() {
        defaults.set(todayTotalML, forKey: Keys.todayTotalML)
        defaults.set(totalDayKey, forKey: Keys.todayTotalDayKey)
        defaults.set(dailyGoalML, forKey: Keys.dailyGoalML)
        defaults.set(measurementSystem.rawValue, forKey: Keys.measurementSystem)
    }

    /// The phone is the source of truth for the day the context describes — but only for
    /// that day.
    ///
    /// Application context delivery is opportunistic, so a context sent last night can
    /// arrive this morning. Applying its total unconditionally showed yesterday's intake
    /// as today's, and stamping it as fresh meant the staleness check never caught it.
    fileprivate func applyContext(_ context: [String: Any]) {
        let today = DayKey.key(for: Date())
        if let total = context["todayTotalML"] as? Int, context["dayKey"] as? String == today {
            todayTotalML = total
            totalDayKey = today
        } else {
            // Nothing usable about today in this context; make sure a yesterday total
            // isn't still sitting on screen.
            resetTotalIfNewDay()
        }
        if let goal = context["dailyGoalML"] as? Int {
            dailyGoalML = goal
        }
        if let raw = context["measurementSystem"] as? String, let system = MeasurementSystem(rawValue: raw) {
            measurementSystem = system
        }
        persist()
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            WatchSessionManager.shared.flushOutbox()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            WatchSessionManager.shared.applyContext(applicationContext)
        }
    }
}
