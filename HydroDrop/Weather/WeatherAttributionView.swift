import SwiftUI
import WeatherKit

/// Caches the one WeatherKit attribution fetch so every place that shows weather-derived
/// content in the app can share it instead of each re-fetching its own copy.
@MainActor
final class WeatherAttributionStore: ObservableObject {
    static let shared = WeatherAttributionStore()

    @Published private(set) var attribution: WeatherAttribution?

    private var isLoading = false

    private init() {}

    func loadIfNeeded() async {
        guard attribution == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        attribution = try? await WeatherService.shared.attribution
    }
}

/// Required attribution for any HydroDrop surface that shows WeatherKit-derived data.
///
/// Apple's WeatherKit terms require the "Weather" mark — or the word "Weather" as a
/// fallback while the mark loads — linked to Apple's legal attribution page, placed
/// wherever weather data is shown. That's the hot-day suggestion from
/// `WeatherGoalAdvisor`, surfaced in `WeatherBumpCard` and `WeatherBumpBadge`.
struct WeatherAttributionLink: View {
    @ObservedObject private var store = WeatherAttributionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        Group {
            if let attribution = store.attribution {
                let markURL = colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkURL
                Link(destination: attribution.legalPageURL) {
                    AsyncImage(url: markURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFit()
                        } else {
                            fallbackText
                        }
                    }
                    .frame(height: 11)
                }
            } else {
                Link(destination: Self.fallbackLegalURL) {
                    fallbackText
                }
            }
        }
        .task { await store.loadIfNeeded() }
    }

    private var fallbackText: some View {
        Text("Weather")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
