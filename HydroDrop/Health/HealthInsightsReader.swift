import Foundation
import HealthKit

/// The only place HydroDrop reads from Apple Health.
///
/// Four things, and only these: sleep, resting heart rate, workouts and active energy.
/// Access is asked for in exactly one place, when a subscriber taps Connect in Insights,
/// and never as a side effect of anything else. `HealthKitManager`, which writes the
/// drinks, asks for no read access at all and is untouched by this.
///
/// What comes back lives in memory for as long as the screen that asked for it. It is
/// not saved to the store, not synced, not shared with a duo and not shown in a widget.
actor HealthInsightsReader {
    static let shared = HealthInsightsReader()

    private static let connectedKey = "insights.connected"

    private let store = HKHealthStore()

    private static let sleepType = HKCategoryType(.sleepAnalysis)
    private static let restingHeartRateType = HKQuantityType(.restingHeartRate)
    private static let activeEnergyType = HKQuantityType(.activeEnergyBurned)
    private static let workoutType = HKObjectType.workoutType()

    private static var readTypes: Set<HKObjectType> {
        [sleepType, restingHeartRateType, activeEnergyType, workoutType]
    }

    nonisolated static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Whether Connect has been tapped on this device. Health never says whether read
    /// access was actually granted, by design, so this records that the question was
    /// asked, which is all anyone can know. Device-local: permission is per device.
    nonisolated static var isConnected: Bool {
        get { UserDefaults.standard.bool(forKey: connectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: connectedKey) }
    }

    /// Shows the system's Health sheet. True once it has been answered, either way.
    func connect() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            Self.isConnected = true
            return true
        } catch {
            Diagnostics.log("could not ask for Health read access: \(error)")
            return false
        }
    }

    // MARK: - Reading

    /// The last couple of months, a value a day. Anything that cannot be read comes back
    /// empty rather than as an error: declined access and no data look the same from
    /// here, and both mean "nothing to compare yet".
    func dailyHealth(now: Date = Date(), calendar: Calendar = .current) async -> DailyHealth {
        guard Self.isAvailable, Self.isConnected else { return DailyHealth() }
        let end = now
        let start = calendar.date(byAdding: .day, value: -(InsightsEngine.windowDays + 1), to: calendar.startOfDay(for: now)) ?? now

        async let sleep = sleepMinutes(from: start, to: end, calendar: calendar)
        async let heart = dailyStatistic(Self.restingHeartRateType, options: .discreteAverage, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end, calendar: calendar)
        async let energy = dailyStatistic(Self.activeEnergyType, options: .cumulativeSum, unit: .kilocalorie(), from: start, to: end, calendar: calendar)

        return DailyHealth(
            sleepMinutesByWakeDay: await sleep,
            restingHeartRateByDay: await heart,
            activeEnergyByDay: await energy
        )
    }

    /// How long each of today's finished workouts lasted, in minutes.
    func workoutMinutesEndedToday(now: Date = Date(), calendar: Calendar = .current) async -> [Double] {
        guard Self.isAvailable, Self.isConnected else { return [] }
        let startOfDay = calendar.startOfDay(for: now)
        // Ended today. One that started last night and ran past midnight still counts.
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay.addingTimeInterval(-12 * 60 * 60), end: now)
        let samples = await samples(of: Self.workoutType, predicate: predicate)
        return samples
            .compactMap { $0 as? HKWorkout }
            .filter { $0.endDate >= startOfDay && $0.endDate <= now }
            .map { $0.duration / 60 }
    }

    private func sleepMinutes(from start: Date, to end: Date, calendar: Calendar) async -> [String: Double] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples = await samples(of: Self.sleepType, predicate: predicate)
        let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let asleep = samples
            .compactMap { $0 as? HKCategorySample }
            .filter { asleepValues.contains($0.value) }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        return SleepNights.minutesByWakeDay(asleep, calendar: calendar)
    }

    private func samples(of type: HKSampleType, predicate: NSPredicate) async -> [HKSample] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { Diagnostics.log("a Health read came back empty: \(error.localizedDescription)") }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }

    /// One number a day, worked out by Health itself, which also takes care of the same
    /// reading arriving from a watch and a phone.
    private func dailyStatistic(
        _ type: HKQuantityType,
        options: HKStatisticsOptions,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) async -> [String: Double] {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: options,
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error { Diagnostics.log("a Health statistic came back empty: \(error.localizedDescription)") }
                var values: [String: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
                    guard let value = quantity?.doubleValue(for: unit), value > 0 else { return }
                    values[DayKey.key(for: statistics.startDate, calendar: calendar)] = value
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
}
