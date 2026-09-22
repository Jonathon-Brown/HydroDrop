import Foundation
import WatchConnectivity
import SwiftData

/// Bridges the iPhone app to the paired Apple Watch app over WatchConnectivity.
/// The iPhone is the source of truth: it saves entries logged from the watch
/// into SwiftData, and mirrors today's total/goal back so the watch UI stays current.
@MainActor
final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    private var modelContext: ModelContext?

    /// Identifiers of drinks already saved, so a redelivered payload can't log the same
    /// drink twice. Persisted because a background-launched app is torn down again
    /// almost immediately, and an in-memory set would forget between deliveries.
    private static let seenIdentifiersKey = "watch.seenLogIdentifiers"
    private static let seenIdentifierLimit = 100

    private override init() { super.init() }

    func activate(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Pushes the current today total / goal / units so the watch reflects them next time it wakes.
    ///
    /// The day the total belongs to travels with it. Application context delivery is
    /// opportunistic — a context sent at 23:58 can arrive after midnight — and without
    /// the day the watch had no way to tell yesterday's total from today's.
    func pushContext(totalML: Int, goalML: Int, measurementSystem: MeasurementSystem, quickAddPresetsML: [Int]) {
        guard canReachWatchApp else { return }
        do {
            try WCSession.default.updateApplicationContext([
                "todayTotalML": totalML,
                "dailyGoalML": goalML,
                "measurementSystem": measurementSystem.rawValue,
                "quickAddPresetsML": quickAddPresetsML,
                "dayKey": DayKey.key(for: Date()),
            ])
        } catch {
            Diagnostics.log("failed to push watch context: \(error)")
        }
    }

    /// Whether there is anything on the other end to receive a context.
    ///
    /// A supported, activated session is not enough. With no watch paired, or a watch
    /// that has not installed the companion app, `updateApplicationContext` fails — and
    /// how it fails depends on the OS. On iOS 26 it throws a `WCError` the `catch` above
    /// absorbs. On iOS 27 it raises `NSInternalInconsistencyException` ("No eligible
    /// connection available"), an Objective-C exception that a Swift `catch` cannot
    /// intercept: it takes the process down with it. Asking first is the only defence.
    ///
    /// It also keeps `WCErrorCodeWatchAppNotInstalled` out of the device log, which every
    /// push was writing there for anyone without the watch app.
    private var canReachWatchApp: Bool {
        WCSession.isSupported()
            && WCSession.default.activationState == .activated
            && WCSession.default.isPaired
            && WCSession.default.isWatchAppInstalled
    }

    /// Re-reads today's total from the store and mirrors it to the watch.
    ///
    /// Needed after a watch-originated drink: `HomeView` only pushes context while it is
    /// on screen, so a drink logged from the wrist left the watch showing its own
    /// optimistic total and the phone showing the real one. The same applies to a drink
    /// logged from a notification action, which is why this is not private.
    func pushCurrentContext() {
        guard let modelContext else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<WaterEntry>(
            predicate: #Predicate { $0.timestamp >= startOfDay }
        )
        let total = (try? modelContext.fetch(descriptor))?.reduce(0) { $0 + $1.hydratedML } ?? 0
        let settings = AppSettings.shared
        pushContext(
            totalML: total,
            goalML: settings.dailyGoalML,
            measurementSystem: settings.measurementSystem,
            quickAddPresetsML: settings.quickAddPresets
        )
    }

    private func handleLogDrink(amountML: Int, timestamp: Date, identifier: String?) {
        guard let modelContext else {
            Diagnostics.log("dropped a watch drink: no model context")
            return
        }
        if let identifier, hasAlreadySaved(identifier) {
            return
        }

        // This is a drink the user logged on their wrist and watched register there.
        // Swallowing a failure silently loses it with no trace at all, which is why
        // `DrinkLogger` names the reason in Console before rolling back.
        guard (try? DrinkLogger.logInApp(
            amountML: amountML,
            timestamp: timestamp,
            in: modelContext,
            loggedBy: "the watch",
            // A wrist-logged drink has never re-paced the reminder schedule.
            followUp: .init(reminderGoalML: nil, mirrorsToWatch: true)
        )) != nil else { return }
        if let identifier { rememberSaved(identifier) }
    }

    private func hasAlreadySaved(_ identifier: String) -> Bool {
        let seen = UserDefaults.standard.stringArray(forKey: Self.seenIdentifiersKey) ?? []
        return seen.contains(identifier)
    }

    private func rememberSaved(_ identifier: String) {
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenIdentifiersKey) ?? []
        seen.append(identifier)
        if seen.count > Self.seenIdentifierLimit {
            seen.removeFirst(seen.count - Self.seenIdentifierLimit)
        }
        UserDefaults.standard.set(seen, forKey: Self.seenIdentifiersKey)
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Diagnostics.log("watch session activation failed: \(error)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The paired-watch picture is not settled the instant activation completes: `isPaired`
    /// and `isWatchAppInstalled` can still read false for a beat after that. Now that a push
    /// is gated on both, a cold launch could quietly skip its first one and leave the watch
    /// showing a stale total until the next drink. WatchConnectivity says when the picture
    /// changes, so push again when it does.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchSessionManager.shared.pushCurrentContext()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["type"] as? String == "logDrink" else { return }
        guard let amountML = userInfo["amountML"] as? Int else {
            Diagnostics.log("dropped a watch payload with no amount: \(userInfo.keys.sorted())")
            return
        }
        // The amount crosses a process boundary, so it is input, not a given.
        guard MeasurementSystem.plausibleDrinkRangeML.contains(amountML) else {
            Diagnostics.log("dropped a watch drink with an implausible amount: \(amountML)")
            return
        }
        let timestamp = (userInfo["timestamp"] as? Date) ?? Date()
        let identifier = userInfo["id"] as? String
        Task { @MainActor in
            WatchSessionManager.shared.handleLogDrink(
                amountML: amountML,
                timestamp: timestamp,
                identifier: identifier
            )
        }
    }
}
