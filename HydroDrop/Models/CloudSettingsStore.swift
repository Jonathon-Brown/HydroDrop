import Foundation

/// Storage for the preferences that belong to the person rather than to the device.
///
/// Hydration entries sync through CloudKit, but the goal they are measured against and
/// the freezes already spent lived only in local `UserDefaults`. Two devices therefore
/// computed different streaks from identical data, and each one handed out its own
/// "one freeze per month".
///
/// Key-value storage is the right size for this: a handful of small values, no schema to
/// model or deploy, and — importantly — a local mirror that keeps working unchanged when
/// iCloud is unavailable or the user isn't signed in. Everything written here is also
/// written to `UserDefaults`, so a device that never reaches iCloud behaves exactly as it
/// did before.
///
/// Reminder settings are deliberately *not* synced: notifications are scheduled per
/// device, and a waking window is a property of the phone in your pocket.
final class CloudSettingsStore {
    static let shared = CloudSettingsStore()

    private let local = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    /// Screenshot automation runs against whatever iCloud account the machine is signed
    /// into, which would make captures depend on another device's settings — and let a
    /// test run write to them. Local-only there. Compiled out of Release.
    private let isCloudEnabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory")
        #else
        true
        #endif
    }()

    private init() {}

    // MARK: - Reading

    /// iCloud wins when it has an opinion. Local is the answer for a device that has
    /// never synced, and the fallback for a user who isn't signed in.
    func object(forKey key: String) -> Any? {
        guard isCloudEnabled else { return local.object(forKey: key) }
        return cloud.object(forKey: key) ?? local.object(forKey: key)
    }

    func int(forKey key: String) -> Int? { object(forKey: key) as? Int }
    func bool(forKey key: String) -> Bool? { object(forKey: key) as? Bool }
    func double(forKey key: String) -> Double? { object(forKey: key) as? Double }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }

    /// Whether iCloud itself holds a value, ignoring the local mirror. Used to decide
    /// whether this device's settings should seed an empty cloud.
    func hasCloudValue(forKey key: String) -> Bool {
        isCloudEnabled && cloud.object(forKey: key) != nil
    }

    // MARK: - Writing

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            local.removeObject(forKey: key)
            if isCloudEnabled { cloud.removeObject(forKey: key) }
            return
        }
        local.set(value, forKey: key)
        if isCloudEnabled { cloud.set(value, forKey: key) }
    }

    // MARK: - Change notification

    /// Starts mirroring remote edits into the local store and hands the changed keys to
    /// `handler` on the main queue.
    ///
    /// Call this once, after whatever owns the settings has finished initialising —
    /// never from inside that initialiser.
    func startObserving(_ handler: @escaping ([String]) -> Void) {
        guard isCloudEnabled, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard !keys.isEmpty else { return }
            // Mirror down, so the next launch reads the newest value even offline.
            for key in keys {
                if let value = self.cloud.object(forKey: key) {
                    self.local.set(value, forKey: key)
                } else {
                    self.local.removeObject(forKey: key)
                }
            }
            handler(keys)
        }
        // Ask for whatever arrived while this device was away.
        cloud.synchronize()
    }
}
