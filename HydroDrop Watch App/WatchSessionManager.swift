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

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let todayTotalML = "watch.todayTotalML"
        static let dailyGoalML = "watch.dailyGoalML"
    }

    private override init() {
        todayTotalML = defaults.object(forKey: Keys.todayTotalML) as? Int ?? 0
        dailyGoalML = defaults.object(forKey: Keys.dailyGoalML) as? Int ?? 2000
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Optimistically applies the drink locally, then queues it for reliable delivery to the phone.
    func logDrink(amountML: Int) {
        todayTotalML += amountML
        persist()

        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "logDrink",
            "amountML": amountML,
            "timestamp": Date(),
        ])
    }

    private func persist() {
        defaults.set(todayTotalML, forKey: Keys.todayTotalML)
        defaults.set(dailyGoalML, forKey: Keys.dailyGoalML)
    }

    fileprivate func applyContext(_ context: [String: Any]) {
        if let total = context["todayTotalML"] as? Int {
            todayTotalML = total
        }
        if let goal = context["dailyGoalML"] as? Int {
            dailyGoalML = goal
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
