import CoreLocation
import Foundation
import WeatherKit

/// How much extra water a hot day is worth suggesting.
///
/// Kept as a pure function so the rule can be read, argued with and tested without a
/// forecast or a location. The numbers are a rule of thumb in the same spirit as the
/// goal calculator: enough to matter on a hot day, never enough to be alarming.
enum WeatherGoalAdvice {
    /// Below this, a day is not hot enough to say anything about.
    static let thresholdCelsius = 27.0

    /// Suggested extra millilitres for the day, or nil when the weather does not
    /// warrant mentioning.
    ///
    /// Uses apparent temperature rather than the raw reading, because humidity is most
    /// of what makes a day costly to be out in.
    static func suggestedBumpML(apparentTemperatureC: Double, baseGoalML: Int) -> Int? {
        guard apparentTemperatureC.isFinite, apparentTemperatureC >= thresholdCelsius else { return nil }

        let bump: Int
        switch apparentTemperatureC {
        case ..<30: bump = 250
        case ..<34: bump = 500
        default: bump = 750
        }

        // Never suggest a target the goal stepper itself would refuse.
        let ceiling = MeasurementSystem.storedGoalRangeML.upperBound
        let allowed = max(0, ceiling - baseGoalML)
        let capped = min(bump, allowed)
        return capped > 0 ? capped : nil
    }
}

/// Fetches today's weather for the device's location and turns it into a suggestion.
///
/// Location is asked for only when the user turns this on, is used once per day, and
/// never leaves the device: the coordinate goes to Apple's weather service and nowhere
/// else. Everything here fails quietly, because a goal suggestion is not worth an error
/// message and certainly not worth blocking the app on.
@MainActor
final class WeatherGoalAdvisor: NSObject {
    static let shared = WeatherGoalAdvisor()

    private let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var isFetching = false

    private override init() {
        super.init()
        locationManager.delegate = self
        // A goal suggestion does not need to know which room you are in.
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    enum SetupOutcome: Equatable {
        case granted
        case denied
        case failed(String)
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    /// Asks for location permission, returning what the user decided.
    func requestLocationAccess() async -> SetupOutcome {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // The delegate reports the answer; poll briefly rather than hold a
            // continuation across a callback that may never come if the user swipes away.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                switch locationManager.authorizationStatus {
                case .authorizedWhenInUse, .authorizedAlways: return .granted
                case .denied, .restricted: return .denied
                default: continue
                }
            }
            return .failed("HydroDrop did not get an answer about location access.")
        @unknown default:
            return .failed("HydroDrop could not read this device's location setting.")
        }
    }

    /// Today's suggested bump, or nil when it is not hot enough, the forecast cannot be
    /// reached, or location is not available.
    func suggestedBumpML(baseGoalML: Int) async -> Int? {
        guard !isFetching else { return nil }
        isFetching = true
        defer { isFetching = false }

        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil
        }

        guard let location = await currentLocation() else { return nil }
        do {
            let current = try await weatherService.weather(for: location, including: .current)
            let apparent = current.apparentTemperature.converted(to: .celsius).value
            return WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: apparent, baseGoalML: baseGoalML)
        } catch {
            Diagnostics.log("could not fetch the weather: \(error)")
            return nil
        }
    }

    private func currentLocation() async -> CLLocation? {
        // A location already in hand is good enough for a temperature, and costs nothing.
        if let cached = locationManager.location, cached.timestamp.timeIntervalSinceNow > -3_600 {
            return cached
        }
        return await withCheckedContinuation { continuation in
            guard locationContinuation == nil else {
                continuation.resume(returning: nil)
                return
            }
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    private func finishLocationRequest(with location: CLLocation?) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: location)
    }
}

extension WeatherGoalAdvisor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            WeatherGoalAdvisor.shared.finishLocationRequest(with: last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Diagnostics.log("could not read the device location: \(error)")
        Task { @MainActor in
            WeatherGoalAdvisor.shared.finishLocationRequest(with: nil)
        }
    }
}
