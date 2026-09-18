import Foundation
import CoreData
import SwiftData

/// Runs the duplicate-collapsing pass when CloudKit delivers remote changes, not only at
/// launch, so the doubled totals a migration leaves behind are gone before the user can
/// see them rather than on the next cold start.
///
/// SwiftData is `NSPersistentCloudKitContainer` underneath, and that posts
/// `.NSPersistentStoreRemoteChange` when the mirror imports records from iCloud — the
/// same notification a Core Data app would watch. A single sync arrives as a burst of
/// these, so the pass is debounced: a run is scheduled a short time out and pushed back
/// by each further notification, collapsing a burst into one pass.
@MainActor
final class StoreRemoteChangeObserver {
    private let container: ModelContainer
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    /// How long to wait for a burst of remote-change notifications to settle before
    /// running one pass. Long enough to fold an import into a single run, short enough
    /// that the correction still feels immediate.
    private let debounceInterval: TimeInterval = 1.0

    init(container: ModelContainer) {
        self.container = container
    }

    /// Begins watching for remote changes. Call once, after the app's container exists.
    /// Observing `object: nil` rather than a specific coordinator because SwiftData does
    /// not expose the store coordinator it posts from; this process has only the one
    /// hydration store, so there is nothing else to confuse it with.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop back to the main actor: the notification block is nonisolated, but the
            // debounce state and the pass both belong on the main actor.
            Task { @MainActor in self?.scheduleDeduplicate() }
        }
    }

    private func scheduleDeduplicate() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            StoreMigration.deduplicateIfNeeded(in: self.container)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
