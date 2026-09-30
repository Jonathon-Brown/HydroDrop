#if DEBUG
import HealthKit
import Network
import SwiftData
import SwiftUI
import UIKit

/// A throwaway two-device test of HealthKit's sync identifiers, run before 1.9's Health
/// changes are built on them.
///
/// 1.9 was designed to let any device with Health sync on replace an edited drink's sample,
/// with `HKMetadataKeySyncIdentifier` stopping two devices doing the same replacement from
/// leaving two samples. With no second device to try it on, 1.9 has only the sample's owner
/// replace it, and this screen is what could show the wider design is safe. Apple documents
/// only that a save replaces a matching sample with a
/// lower version. It says nothing about equal versions, about iCloud Health sync between
/// devices, or about deleting by metadata with permission to write but not to read. This
/// screen does each of those by hand, on two devices, so the answers come from Health
/// itself rather than from reading the documentation.
///
/// Debug only, and shown when the app is launched with `-HealthStep0`. That is remembered,
/// even past Finish, until "Leave test mode": a launch from the Home Screen passes no
/// arguments, and a Debug build that opened the real store would sync it with the
/// development CloudKit environment. While test mode is on the app opens an empty scratch
/// store with no iCloud, and the widget and the App Intents refuse to open the real one
/// (see `SharedModelContainer.healthStep0IsShowing`).
///
/// Every sample it writes is dietary water early on 28 September 2026, each test at its
/// own minute, small, and marked with `metadataKey`, so it is easy to tell apart in the
/// Health app and Finish can find every one of them again.
enum HealthStep0 {
    static let argument = "-HealthStep0"
    /// Everything this screen keeps in the app's defaults starts with this.
    static let keyPrefix = "debug.healthStep0."
    static let activeKey = keyPrefix + "active"
    static let finishedKey = keyPrefix + "finished"
    static let runKey = keyPrefix + "run"
    static let logKey = keyPrefix + "log"
    /// On every sample this screen writes. Health allows custom metadata keys that don't
    /// start with "HK".
    static let metadataKey = "HydroDropStep0"

    /// A version shaped like the ones 1.9 writes, which are milliseconds since 1970 and so
    /// well above 2^32. A test built on small numbers could pass while real versions were
    /// cut short somewhere.
    static let baseVersion: Int64 = 1_790_000_000_000

    /// Read once, so the app's initialiser and its scene agree for the whole launch.
    static let isActive: Bool = {
        let process = ProcessInfo.processInfo
        // The unit tests and UI tests launch this same Debug app on a simulator, where a
        // test run that never reached Finish would otherwise take them over.
        if process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains(where: { $0.hasPrefix("-UITest") }) {
            SharedModelContainer.healthStep0IsShowing = false
            return false
        }
        if process.arguments.contains(argument) {
            UserDefaults.standard.set(true, forKey: activeKey)
        }
        let active = UserDefaults.standard.bool(forKey: activeKey)
        SharedModelContainer.healthStep0IsShowing = active
        return active
    }()

    /// An empty store in the app's own temporary directory, with no CloudKit, for the scene
    /// to hold while this screen shows. The App Group store with the user's real log is
    /// never opened.
    static func makeScratchContainer() -> ModelContainer {
        let directory = URL.temporaryDirectory.appending(path: "HydroDropHealthStep0Store")
        try? FileManager.default.removeItem(at: directory)
        let configuration = ModelConfiguration(
            schema: SharedModelContainer.schema,
            url: directory.appending(path: "store.sqlite"),
            cloudKitDatabase: .none
        )
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let container = try? ModelContainer(for: SharedModelContainer.schema, configurations: configuration) else {
            fatalError("Failed to create the Health Step 0 scratch store")
        }
        return container
    }

    /// The minute past 3 AM each test's samples are dated, so they can be told apart in
    /// the Health app, which lists them by time.
    static func minute(for test: String) -> Int {
        switch test {
        case "T1": return 1
        case "T2": return 2
        case "T2b": return 3
        case let test where test.hasPrefix("T4a"): return 5
        case "T4b": return 6
        case "T5": return 7
        default: return 4 // T3 and its reruns
        }
    }

    /// The day each run's samples are dated: 28 September 2026 for run A, the 27th for B,
    /// the 26th for C, so the Health app never shows two runs' samples side by side.
    static func day(for run: String) -> Int {
        switch run {
        case "B": return 27
        case "C": return 26
        default: return 28
        }
    }

    /// Early on a fixed past day, so none of them lands on today's total or among real
    /// drinks.
    static func sampleDate(for test: String, run: String) -> Date {
        let components = DateComponents(year: 2026, month: 9, day: day(for: run), hour: 3, minute: minute(for: test))
        return Calendar.current.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 812_257_200)
    }
}

/// Everything the screen does to Health, and the log of what came back.
@MainActor
final class HealthStep0Runner: ObservableObject {
    @Published private(set) var log: [String]
    @Published private(set) var visibleSamples: [String] = []
    /// What the other device shared for T5: "<its identifierForVendor>|<sample UUID>".
    @Published private(set) var sharedT5: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isFinished: Bool
    @Published private(set) var hasLeft = false
    @Published private(set) var networkStatus = "unknown"
    /// Which set of sync identifiers to use. The same letter on both devices; a new letter
    /// starts the tests again without meeting the samples of an earlier attempt. Kept, so a
    /// relaunch can't silently switch back to A.
    @Published var run: String {
        didSet {
            UserDefaults.standard.set(run, forKey: HealthStep0.runKey)
            refreshShared()
        }
    }

    private let store = HKHealthStore()
    private let water = HKQuantityType(.dietaryWater)
    private let cloud = NSUbiquitousKeyValueStore.default
    private let pathMonitor = NWPathMonitor()
    private var cloudObserver: NSObjectProtocol?
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"

    init() {
        log = UserDefaults.standard.stringArray(forKey: HealthStep0.logKey) ?? []
        isFinished = UserDefaults.standard.bool(forKey: HealthStep0.finishedKey)
        run = UserDefaults.standard.string(forKey: HealthStep0.runKey) ?? "A"
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshShared() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = Self.describe(path)
            Task { @MainActor in self?.networkStatus = status }
        }
        pathMonitor.start(queue: DispatchQueue(label: "HealthStep0.network"))
        cloud.synchronize()
        refreshShared()
        record("Opened, run \(run). Health available: \(isHealthAvailable ? "yes" : "NO"). Writing water: \(writeStatus). Device: \(deviceDescription).")
    }

    deinit {
        pathMonitor.cancel()
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    // MARK: - This device

    var isHealthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var writeStatus: String {
        guard isHealthAvailable else { return "no Health on this device" }
        switch store.authorizationStatus(for: water) {
        case .sharingAuthorized: return "allowed"
        case .sharingDenied: return "NOT allowed"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    var deviceDescription: String {
        let device = UIDevice.current
        return "\(device.model), \(device.systemName) \(device.systemVersion)"
    }

    /// Asks to write water and nothing else, as the real app does. Reading is never asked
    /// for: T4 and T5 are about what a device can delete with permission to write alone.
    func askPermission() async {
        do {
            try await store.requestAuthorization(toShare: [water], read: [])
            record("Permission asked. Writing water: \(writeStatus).")
        } catch {
            record("Permission request FAILED: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    // MARK: - Samples

    func syncIdentifier(_ test: String) -> String {
        "hydrodrop.step0.\(run).\(test)"
    }

    /// Saves one test sample and returns its UUID, or nil if Health refused it.
    @discardableResult
    func save(_ test: String, version: Int64, amountML: Double) async -> String? {
        let identifier = syncIdentifier(test)
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: identifier,
            HKMetadataKeySyncVersion: NSNumber(value: version),
            HealthStep0.metadataKey: "1",
        ]
        let date = HealthStep0.sampleDate(for: test, run: run)
        let sample = HKQuantitySample(
            type: water,
            quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: amountML),
            start: date,
            end: date,
            metadata: metadata
        )
        let what = "\(identifier) v\(version) (\(Int(amountML)) mL at 3:0\(HealthStep0.minute(for: test)) AM on \(HealthStep0.day(for: run)) September), network \(networkStatus)"
        do {
            try await store.save(sample)
            let uuid = sample.uuid.uuidString
            UserDefaults.standard.set(uuid, forKey: uuidKey(test))
            record("Saved \(what). Health said OK. UUID \(uuid.prefix(8)).")
            return uuid
        } catch {
            record("Save of \(what) FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    /// The UUID of the last sample this device saved for a test, kept across launches.
    func savedUUID(_ test: String) -> String? {
        UserDefaults.standard.string(forKey: uuidKey(test))
    }

    /// Logs what this device holds for a test, as far as Health lets an app that can only
    /// write see.
    func check(_ test: String) async {
        await logHeld(test, after: "check")
    }

    func deleteBySyncIdentifier(_ test: String) async {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            allowedValues: [syncIdentifier(test)]
        )
        let count = await delete(matching: predicate)
        record("\(syncIdentifier(test)): delete by sync identifier, network \(networkStatus) -> \(describe(count)).\(retryHint(count))")
    }

    /// T2b: the 1.9 replacement itself, delete then write, done offline on both devices at
    /// once from the same synced sample.
    func deleteThenSave(_ test: String, version: Int64, amountML: Double) async {
        await deleteBySyncIdentifier(test)
        await save(test, version: version, amountML: amountML)
        await logHeld(test, after: "delete then save")
    }

    /// The predicate 1.9 uses: this sample's UUID, or its sync identifier.
    func deleteByUUIDOrSyncIdentifier(_ test: String) async {
        guard let uuidString = savedUUID(test), let uuid = UUID(uuidString: uuidString) else {
            record("\(syncIdentifier(test)): nothing saved on this device yet, so there is no UUID to delete by.")
            return
        }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(with: [uuid]),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier(test)]),
        ])
        let count = await delete(matching: predicate)
        record("\(syncIdentifier(test)): delete by UUID \(uuidString.prefix(8)) OR sync identifier -> \(describe(count)).")
    }

    /// T5's first half: saves the sample and shares its UUID with the other device through
    /// iCloud key-value storage, which is the one channel both copies of the app share.
    func saveAndShareT5() async {
        guard let uuid = await save("T5", version: HealthStep0.baseVersion + 1, amountML: 16) else { return }
        cloud.set("\(deviceID)|\(uuid)", forKey: sharedKey)
        cloud.synchronize()
        record("\(syncIdentifier("T5")): shared UUID \(uuid.prefix(8)) through iCloud key-value storage.")
    }

    var sharedT5Summary: String {
        guard let parts = sharedParts else { return "none yet" }
        return parts.writer == deviceID ? "\(parts.uuid.prefix(8)), from this device" : String(parts.uuid.prefix(8))
    }

    /// T5's second half: deletes, by UUID alone, the sample the other device shared.
    func deleteSharedUUID() async {
        guard let parts = sharedParts, let uuid = UUID(uuidString: parts.uuid) else {
            record("\(syncIdentifier("T5")): no UUID has arrived from the other device yet. Tap Refresh, or wait a minute.")
            return
        }
        guard parts.writer != deviceID else {
            record("\(syncIdentifier("T5")): the shared UUID is this device's own sample. Run this step on the other device.")
            return
        }
        await logHeld("T5", after: "the UUID \(parts.uuid.prefix(8)) arrived")
        let count = await delete(matching: HKQuery.predicateForObjects(with: [uuid]))
        record("\(syncIdentifier("T5")): delete by the other device's UUID \(parts.uuid.prefix(8)) -> \(describe(count)).\(retryHint(count))")
    }

    func refreshShared() {
        cloud.synchronize()
        sharedT5 = cloud.string(forKey: sharedKey)
    }

    /// T3 in one go, on one device, logging what Health holds after every step. A fresh
    /// sync identifier each time, so running it again never meets an earlier attempt.
    ///
    /// Answers: does an equal version replace, is a lower version refused or silently
    /// dropped, after a delete is a lower version than the deleted one stored, and is a
    /// version above 2^32 kept whole.
    func runT3() async {
        let attempt = UserDefaults.standard.integer(forKey: HealthStep0.keyPrefix + "t3Attempt") + 1
        UserDefaults.standard.set(attempt, forKey: HealthStep0.keyPrefix + "t3Attempt")
        let test = "T3-\(attempt)"
        record("\(syncIdentifier(test)): starting. Each step is followed by what Health holds for it.")
        await save(test, version: 5, amountML: 51)
        await logHeld(test, after: "a (save v5, 51 mL)")
        await save(test, version: 5, amountML: 52)
        await logHeld(test, after: "b (save v5 again, 52 mL)")
        await save(test, version: 3, amountML: 31)
        await logHeld(test, after: "c (save v3, 31 mL)")
        await deleteBySyncIdentifier(test)
        await logHeld(test, after: "d (delete by sync identifier)")
        await save(test, version: 4, amountML: 41)
        await logHeld(test, after: "e (save v4, 41 mL, after the delete)")
        await save(test, version: 4_294_967_297, amountML: 61)
        await logHeld(test, after: "f (save v4294967297, 61 mL)")
        record("\(syncIdentifier(test)): done.")
    }

    /// T4's first half in one go: save, then delete by UUID or sync identifier. A fresh sync
    /// identifier each time, so a second attempt never saves over a deleted sample, which
    /// is a different question (T3 step e).
    func runT4a() async {
        let attempt = UserDefaults.standard.integer(forKey: HealthStep0.keyPrefix + "t4aAttempt") + 1
        UserDefaults.standard.set(attempt, forKey: HealthStep0.keyPrefix + "t4aAttempt")
        let test = "T4a-\(attempt)"
        guard await save(test, version: HealthStep0.baseVersion + 1, amountML: 14) != nil else { return }
        await logHeld(test, after: "the save")
        await deleteByUUIDOrSyncIdentifier(test)
        await logHeld(test, after: "the delete")
    }

    /// Lists every test sample this app can see on this device. Health may show an app
    /// that can't read water only the samples it wrote itself, or none at all, so an empty
    /// list proves nothing; the Health app is the one to trust.
    func listVisibleSamples() async {
        guard let samples = await visible(matching: HKQuery.predicateForObjects(withMetadataKey: HealthStep0.metadataKey)) else {
            record("List: QUERY FAILED (see the line above).")
            return
        }
        visibleSamples = samples.map(Self.describe)
        record("List: this app can see \(samples.count) test sample(s) on this device\(samples.isEmpty ? "." : ":")")
        visibleSamples.forEach { record("  \($0)") }
    }

    /// Deletes every test sample on this device, from any run, and clears what was shared
    /// through iCloud. Test mode stays on, and every step is disabled, so this Debug build
    /// can't open the real app before it is replaced.
    func finish() async {
        guard let count = await delete(matching: HKQuery.predicateForObjects(withMetadataKey: HealthStep0.metadataKey)) else {
            record("Finish: the delete couldn't be done. Unlock the phone and try again.")
            return
        }
        record("Finish: deleted \(count) test sample(s) on this device.")
        for key in cloud.dictionaryRepresentation.keys where key.hasPrefix(HealthStep0.keyPrefix) {
            cloud.removeObject(forKey: key)
        }
        cloud.synchronize()
        let kept: Set<String> = [HealthStep0.activeKey, HealthStep0.finishedKey, HealthStep0.runKey, HealthStep0.logKey]
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(HealthStep0.keyPrefix) && !kept.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: HealthStep0.finishedKey)
        isFinished = true
        record("Finish: done on this device. Install HydroDrop from TestFlight over this build. Don't delete HydroDrop.")
    }

    /// Only for a Debug build that is meant to become the real app again, which this test
    /// never needs: installing from TestFlight is the way back. Clears everything, so the
    /// next launch opens the real store.
    func leaveTestMode() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(HealthStep0.keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SharedModelContainer.healthStep0IsShowing = false
        hasLeft = true
        Diagnostics.log("Health Step 0: left test mode; the next launch opens the real app")
    }

    func run(_ work: @escaping () async -> Void) {
        guard !isBusy, !isFinished else { return }
        isBusy = true
        Task { @MainActor in
            await work()
            isBusy = false
        }
    }

    var logText: String {
        (["HydroDrop Health Step 0, run \(run), \(deviceDescription)"] + log).joined(separator: "\n")
    }

    // MARK: - Private

    private var sharedKey: String {
        HealthStep0.keyPrefix + "\(run).T5.shared"
    }

    private var sharedParts: (writer: String, uuid: String)? {
        guard let sharedT5 else { return nil }
        let parts = sharedT5.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Logs the samples this app can see for one test's sync identifier.
    private func logHeld(_ test: String, after step: String) async {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            allowedValues: [syncIdentifier(test)]
        )
        guard let samples = await visible(matching: predicate) else {
            record("\(syncIdentifier(test)) after \(step): QUERY FAILED, so what it holds is unknown.")
            return
        }
        let held = samples.map(Self.describe)
        record("\(syncIdentifier(test)) after \(step): holds \(held.isEmpty ? "nothing this app can see" : held.joined(separator: "; ")).")
    }

    /// Nil if the query failed, which is not the same as finding nothing.
    private func visible(matching predicate: NSPredicate) async -> [HKQuantitySample]? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: water,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { [weak self] _, results, error in
                if let error {
                    Task { @MainActor in self?.record("Health's query reported: \(error.localizedDescription)") }
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }

    private static func describe(_ sample: HKQuantitySample) -> String {
        let identifier = sample.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "no sync identifier"
        let version = (sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.stringValue ?? "?"
        let amount = Int(sample.quantity.doubleValue(for: .literUnit(with: .milli)).rounded())
        let product = sample.sourceRevision.productType ?? "unknown device"
        return "\(identifier) v\(version): \(amount) mL, from \(product), UUID \(sample.uuid.uuidString.prefix(8))"
    }

    /// Called on the path monitor's queue.
    private nonisolated static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "OFFLINE" }
        if path.usesInterfaceType(.wifi) { return "online (Wi-Fi)" }
        if path.usesInterfaceType(.cellular) { return "online (cellular)" }
        return "online"
    }

    private func delete(matching predicate: NSPredicate) async -> Int? {
        await withCheckedContinuation { continuation in
            store.deleteObjects(of: water, predicate: predicate) { success, count, error in
                if let error {
                    Task { @MainActor in self.record("Health's delete reported: \(error.localizedDescription)") }
                }
                continuation.resume(returning: success && error == nil ? count : nil)
            }
        }
    }

    private func describe(_ count: Int?) -> String {
        guard let count else { return "COULD NOT DELETE" }
        return "deleted \(count)"
    }

    /// A cross-device delete that finds nothing may only mean Health sync hasn't brought
    /// the sample yet.
    private func retryHint(_ count: Int?) -> String {
        count == 0 ? " If the sample isn't in this device's Health app yet, wait for it and tap again before calling it a fail." : ""
    }

    private func uuidKey(_ test: String) -> String {
        HealthStep0.keyPrefix + "\(run).\(test).uuid"
    }

    private func record(_ line: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        log.append("\(time)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
        UserDefaults.standard.set(log, forKey: HealthStep0.logKey)
        Diagnostics.log("Health Step 0: \(line)")
    }
}

/// The test screen. Each button says which device presses it.
struct HealthStep0View: View {
    @StateObject private var runner = HealthStep0Runner()
    @State private var confirmingFinish = false
    @State private var confirmingLeave = false

    private static let v1 = HealthStep0.baseVersion + 1
    private static let v2 = HealthStep0.baseVersion + 2
    private static let v10 = HealthStep0.baseVersion + 10
    private static let v20 = HealthStep0.baseVersion + 20

    var body: some View {
        NavigationStack {
            List {
                if runner.isFinished {
                    Section {
                        Text(runner.hasLeft
                             ? "Test mode is off. The next launch of this Debug build opens HydroDrop itself, on the real data."
                             : "Done on this device. Now install HydroDrop from TestFlight (1.8.1, build 34) over this build. Don't delete HydroDrop first: that would erase this device's own data. Until then, don't open HydroDrop; it will keep showing this screen.")
                        if !runner.hasLeft {
                            Button("Leave test mode", role: .destructive) { confirmingLeave = true }
                        }
                    } header: {
                        Text("Finished")
                    } footer: {
                        Text("Leave test mode only to use this Debug build as your real app. The test never needs it.")
                    }
                } else {
                    Section {
                        Text("While this build is installed, nothing can be logged on this phone: not from a reminder, the widget, Siri or a bottle tag. Note those drinks and add them once HydroDrop is back from TestFlight. Don't log on the watch either: a watch drink waits and may still arrive once HydroDrop is back, so check before adding it again.")
                            .font(.footnote)
                    } header: {
                        Text("Before you start")
                    }
                }

                Section {
                    LabeledContent("Apple Health", value: runner.isHealthAvailable ? "Available" : "NOT available")
                    LabeledContent("Writing water", value: runner.writeStatus)
                    LabeledContent("Network", value: runner.networkStatus)
                    LabeledContent("Device", value: runner.deviceDescription)
                    step("Ask for permission to write water") { await runner.askPermission() }
                    Picker("Run", selection: $runner.run) {
                        ForEach(["A", "B", "C"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(runner.isBusy || runner.isFinished)
                } header: {
                    Text("This device")
                } footer: {
                    Text("Use the same run letter on both devices. Test samples are water early on \(HealthStep0.day(for: runner.run)) September 2026: T1 at 3:01 AM, T2 3:02, T2b 3:03, T3 3:04, T4a 3:05, T4b 3:06, T5 3:07.")
                }

                Section("T1  Replace across devices") {
                    step("1. iPhone: save version 1 (11 mL)") { await runner.save("T1", version: Self.v1, amountML: 11) }
                    step("2. Second device, once 11 mL shows in its Health app: save version 2 (22 mL)") {
                        await runner.save("T1", version: Self.v2, amountML: 22)
                    }
                    step("Either device: check T1") { await runner.check("T1") }
                }

                Section {
                    step("1. iPhone, offline: save version 20 (220 mL)") { await runner.save("T2", version: Self.v20, amountML: 220) }
                    step("2. Second device, offline, after step 1: save version 10 (110 mL)") {
                        await runner.save("T2", version: Self.v10, amountML: 110)
                    }
                    step("Either device: check T2") { await runner.check("T2") }
                } header: {
                    Text("T2  Two versions written offline")
                } footer: {
                    Text("The higher version is saved first. Reconnect the iPhone first and wait until its Health has synced, then the second device, so the lower version is both the later save and the later to reach iCloud. Only \"higher version wins\" then leaves 220 mL.")
                }

                Section {
                    step("1. iPhone, online: save version 1 (105 mL)") { await runner.save("T2b", version: Self.v1, amountML: 105) }
                    step("2. iPhone, offline: delete, then save version 20 (225 mL)") {
                        await runner.deleteThenSave("T2b", version: Self.v20, amountML: 225)
                    }
                    step("3. Second device, offline: delete, then save version 10 (115 mL)") {
                        await runner.deleteThenSave("T2b", version: Self.v10, amountML: 115)
                    }
                    step("Either device: check T2b") { await runner.check("T2b") }
                } header: {
                    Text("T2b  Both devices replace the same sample offline")
                } footer: {
                    Text("Step 2 and 3 only once the 105 mL sample shows in the second device's Health app, and only after both are offline. Reconnect the iPhone first, as in T2.")
                }

                Section {
                    step("iPhone: run T3") { await runner.runT3() }
                } header: {
                    Text("T3  Equal, lower, after a delete, and a large version")
                } footer: {
                    Text("One tap runs six steps on this device and logs what Health holds after each.")
                }

                Section("T4  Delete by UUID or sync identifier") {
                    step("a. iPhone: save 14 mL, then delete it by UUID or sync identifier") { await runner.runT4a() }
                    step("b1. iPhone: save 15 mL") { await runner.save("T4b", version: Self.v1, amountML: 15) }
                    step("b2. Second device, once 15 mL shows in its Health app: delete by sync identifier") {
                        await runner.check("T4b")
                        await runner.deleteBySyncIdentifier("T4b")
                    }
                    step("b3. iPhone, once the 15 mL is gone from the second device: check T4b") { await runner.check("T4b") }
                }

                Section {
                    step("1. iPhone: save 16 mL and share its UUID") { await runner.saveAndShareT5() }
                    LabeledContent("Shared UUID", value: runner.sharedT5Summary)
                    Button("Refresh") { runner.refreshShared() }
                    step("2. Second device, once 16 mL shows in its Health app and the shared UUID has arrived: delete by that UUID") {
                        await runner.deleteSharedUUID()
                    }
                    step("3. iPhone, once the 16 mL is gone from the second device: check T5") { await runner.check("T5") }
                } header: {
                    Text("T5  Delete another device's sample by UUID")
                }

                Section {
                    step("List test samples this app can see") { await runner.listVisibleSamples() }
                    ForEach(Array(runner.visibleSamples.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                } header: {
                    Text("What this app can see")
                } footer: {
                    Text("This app never asks to read water, so Health may show it only its own samples, or none. The Health app is the one to trust.")
                }

                Section {
                    Button("Copy log") { UIPasteboard.general.string = runner.logText }
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                } header: {
                    Text("Log")
                }

                if !runner.isFinished {
                    Section {
                        Button("Delete every test sample on this device", role: .destructive) {
                            confirmingFinish = true
                        }
                        .disabled(runner.isBusy)
                    } footer: {
                        Text("Run this on both devices when the tests are done, after copying the log.")
                    }
                }
            }
            .navigationTitle("Health Step 0")
            .alert("Delete every test sample on this device?", isPresented: $confirmingFinish) {
                Button("Delete", role: .destructive) {
                    runner.run { await runner.finish() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Leave test mode?", isPresented: $confirmingLeave) {
                Button("Leave", role: .destructive) { runner.leaveTestMode() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next launch of this Debug build opens the real app, which syncs with CloudKit's development environment. Install from TestFlight instead unless you mean to.")
            }
        }
    }

    private func step(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) { runner.run(action) }
            .disabled(runner.isBusy || runner.isFinished)
    }
}
#endif
