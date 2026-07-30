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

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let todayTotalML = "watch.todayTotalML"
        static let todayTotalDate = "watch.todayTotalDate"
        static let dailyGoalML = "watch.dailyGoalML"
        static let measurementSystem = "watch.measurementSystem"
    }

    private override init() {
        let storedDate = defaults.object(forKey: Keys.todayTotalDate) as? Date
        let staleTotal = storedDate.map { !Calendar.current.isDateInToday($0) } ?? true
        todayTotalML = staleTotal ? 0 : (defaults.object(forKey: Keys.todayTotalML) as? Int ?? 0)
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

        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "logDrink",
            "amountML": amountML,
            "timestamp": Date(),
        ])
    }

    /// The cached total is only meaningful for the calendar day it was last touched on — a watch
    /// that logs a drink before the phone has resynced today's context must not add onto yesterday's total.
    private func resetTotalIfNewDay() {
        let storedDate = defaults.object(forKey: Keys.todayTotalDate) as? Date
        let isStale = storedDate.map { !Calendar.current.isDateInToday($0) } ?? true
        guard isStale else { return }
        todayTotalML = 0
        persist()
    }

    private func persist() {
        defaults.set(todayTotalML, forKey: Keys.todayTotalML)
        defaults.set(Date(), forKey: Keys.todayTotalDate)
        defaults.set(dailyGoalML, forKey: Keys.dailyGoalML)
        defaults.set(measurementSystem.rawValue, forKey: Keys.measurementSystem)
    }

    /// The phone is the source of truth, so an incoming context always wins and re-anchors "today" to now.
    fileprivate func applyContext(_ context: [String: Any]) {
        if let total = context["todayTotalML"] as? Int {
            todayTotalML = total
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
    ) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }
}
