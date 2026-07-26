import Foundation
import WatchConnectivity
import SwiftData

/// Bridges the iPhone app to the paired Apple Watch app over WatchConnectivity.
/// The iPhone is the source of truth: it saves entries logged from the watch
/// into SwiftData, and mirrors today's total/goal back so the watch UI stays current.
final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    private var modelContext: ModelContext?

    private override init() { super.init() }

    func activate(modelContainer: ModelContainer) {
        modelContext = ModelContext(modelContainer)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Pushes the current today total / goal / units so the watch reflects them next time it wakes.
    func pushContext(totalML: Int, goalML: Int, measurementSystem: MeasurementSystem) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([
            "todayTotalML": totalML,
            "dailyGoalML": goalML,
            "measurementSystem": measurementSystem.rawValue,
        ])
    }

    private func handleLogDrink(amountML: Int, timestamp: Date) {
        guard let modelContext else { return }
        modelContext.insert(WaterEntry(amountML: amountML, timestamp: timestamp))
        try? modelContext.save()
    }
}

extension WatchSessionManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["type"] as? String == "logDrink",
              let amountML = userInfo["amountML"] as? Int else { return }
        let timestamp = (userInfo["timestamp"] as? Date) ?? Date()
        Task { @MainActor in
            WatchSessionManager.shared.handleLogDrink(amountML: amountML, timestamp: timestamp)
        }
    }
}
