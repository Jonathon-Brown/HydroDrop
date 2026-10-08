#if DUO_V2
import BackgroundTasks
import Foundation
import UIKit

/// What the background service asks of the system, so a test can read what was requested.
struct DuoBackgroundSystem {
    /// Hands a request to `BGTaskScheduler`, which replaces any request still pending under the
    /// same identifier, so there is never more than one.
    var submit: @MainActor (BGAppRefreshTaskRequest) throws -> Void
    /// Takes back the request pending under an identifier, if there is one.
    var cancel: @MainActor (String) -> Void
    /// Where a zone or clock change is posted.
    var notificationCenter: NotificationCenter

    static var live: DuoBackgroundSystem {
        DuoBackgroundSystem(submit: { try BGTaskScheduler.shared.submit($0) },
                            cancel: { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) },
                            notificationCenter: .default)
    }
}

/// Opens once, from whichever side gets there first, and resumes its one waiter exactly once. The
/// background handler waits on it for the end of the work or the expiry of the run.
final class DuoFirstOf: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// Duo's background refresh (final design §9.7, §10.6): with nobody looking, read the log,
/// publish what the partner has not heard, fetch, and look at the push upload's zone, then ask for
/// the next run. Duo adds no background mode and sends no silent push: this rides on the `fetch`
/// mode and the one task identifier the iCloud Duo declared (`LegacyDuoCleanup.refreshIdentifier`),
/// and SwiftData's CloudKit mirror keeps `remote-notification`. Exactly one handler is registered
/// for the identifier, in `HydroDropApp`, and it is `handleAppRefresh()`.
@MainActor
final class DuoBackground: DuoBackgrounding {
    /// `<bundle id>.duo.refresh`, declared in `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`.
    /// The same string the cleanup cancels on a tester's phone, read from the one place it is written.
    nonisolated static var refreshIdentifier: String { LegacyDuoCleanup.refreshIdentifier }

    private let dependencies: DuoDependencies
    private let system: DuoBackgroundSystem
    private var observers: DuoSystemObservers?
    /// `dependencies.host`, held weakly, for the reason `DuoSystemObservers` gives.
    private weak var host: DuoHost?

    convenience init(dependencies: DuoDependencies) {
        self.init(dependencies: dependencies, system: .live)
    }

    init(dependencies: DuoDependencies, system: DuoBackgroundSystem) {
        self.dependencies = dependencies
        self.system = system
        host = dependencies.host
        // The one-shot is for the next local midnight, so a new zone, or a clock set by hand,
        // means a new instant.
        let observers = DuoSystemObservers(center: system.notificationCenter)
        observers.observe(.NSSystemTimeZoneDidChange) { [weak self] in self?.zoneOrClockChanged() }
        observers.observe(.NSSystemClockDidChange) { [weak self] in self?.zoneOrClockChanged() }
        observers.observe(UIApplication.significantTimeChangeNotification) { [weak self] in self?.zoneOrClockChanged() }
        self.observers = observers
    }

    func scheduleRefresh() {
        guard let host else { return }
        // Nothing to keep fresh without a live duo, and nothing can be fetched without a credential
        // (a cached live duo with none is a person who has not tapped yet, or an identity the server
        // forgot). Nor for a phone the server has shut out (another phone took the identity, a ban,
        // an app too old to write): a launch does not remember that, so each wake would send one
        // more request with the revoked bearer before learning it again. A request already pending
        // is taken back, or iOS would wake the app once more for nothing after the last duo ended,
        // after Delete my Duo data, or after the refusal.
        guard dependencies.identity?.credential != nil, !Self.isShutOut(host.availability),
              host.duos.contains(where: { !$0.hasEnded }) else {
            system.cancel(Self.refreshIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = DuoBackgroundSchedule.nextEarliestBegin(
            now: dependencies.clock.now, calendar: dependencies.clock.calendar,
            jitterSeconds: DuoBackgroundSchedule.jitterSeconds(random: dependencies.random))
        do {
            try system.submit(request)
        } catch {
            // Expected in the simulator, and on a phone with Background App Refresh turned off;
            // the foreground fetch still runs. The error says nothing about the person.
            let code = (error as NSError).code
            Diagnostics.log("Duo's background refresh was not scheduled (BGTaskScheduler error \(code))")
        }
    }

    /// The availabilities the push service stops at too: the server will refuse whatever is sent.
    private static func isShutOut(_ availability: DuoAvailability) -> Bool {
        switch availability {
        case .disconnected, .banned, .upgradeRequired: return true
        case .unknown, .available, .maintenance, .needsRestoreChoice: return false
        }
    }

    private func zoneOrClockChanged() {
        // Foundation keeps the system zone it first read, so the calendar is told to read it again.
        NSTimeZone.resetSystemTimeZone()
        scheduleRefresh()
    }

    // MARK: - The task

    /// The handler for `refreshIdentifier`. It returns at whichever comes first, the end of the work
    /// or the cancellation iOS makes when the run's time is up, and asks for the next run either
    /// way, or the background path would stop after one expiry.
    ///
    /// Waiting for the work alone is not enough: the sync engine and the op queue do their requests
    /// in tasks of their own, which a cancellation of this one never reaches, so on a poor network
    /// the handler used to run past the 30 seconds or so iOS allows, and iOS may then end the app.
    /// The work is told it was cancelled and is otherwise left to run until iOS suspends the app;
    /// that is safe, since the op queue keeps every request it has not had an answer to and the
    /// in-flight journal replays one whose answer was lost. The push service's zone check is only
    /// started for a run that finished in time.
    static func handleAppRefresh() async {
        await handleAppRefresh(store: .shared)
    }

    static func handleAppRefresh(store: DuoStore) async {
        defer { store.scheduleBackgroundRefresh() }
        guard !Task.isCancelled else { return }
        let finished = DuoFirstOf()
        let work = Task { @MainActor in
            _ = await store.backgroundRefresh()
            // Not awaited: an upload it decides on goes through the op queue, which keeps it, so
            // if iOS suspends the app first it is sent at the next drain (a foreground, the
            // network coming back) rather than lost.
            if !Task.isCancelled { store.dependencies?.push?.reevaluate(.background) }
            finished.open()
        }
        await withTaskCancellationHandler {
            await finished.wait()
        } onCancel: {
            work.cancel()
            finished.open()
        }
    }
}
#endif
