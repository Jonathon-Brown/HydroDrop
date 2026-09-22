import SwiftUI
import WeatherKit

/// Holds the one attribution fetch, so every surface that shows weather-derived content
/// shares it instead of asking for its own copy.
///
/// `WeatherService.attribution` is `async throws` and goes to the network the first
/// time. It is asked for once and kept; a failure leaves it nil and the views fall back
/// to words, which still name the trademark and still link to the legal page.
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
        do {
            attribution = try await WeatherService.shared.attribution
        } catch {
            Diagnostics.log("could not fetch the WeatherKit attribution: \(error)")
        }
    }
}

/// The attribution Apple requires wherever HydroDrop shows something it learned from
/// WeatherKit: the hot-day suggestion in `WeatherBumpCard`, and the badge explaining a
/// raised goal in `WeatherBumpBadge`.
///
/// Apple's terms say you "must clearly display the Apple Weather trademark (Weather), as
/// well as the legal link to other data sources", so the mark is the tappable thing and
/// it opens `legalPageURL`. The image comes from `combinedMarkLightURL` or
/// `combinedMarkDarkURL` to suit the colour scheme, and until it arrives the words stand
/// in, so the trademark is named even on a first launch with no network.
///
/// `legalAttributionText` is the other half, which Apple calls "a legal requirement of
/// using WeatherKit". It is described as being for apps that cannot open the legal page
/// in a Safari view, which this app can, so the link alone is arguably enough. It is
/// shown anyway, in Settings under About: see `WeatherDataSourcesView`.
struct WeatherAttributionLink: View {
    @ObservedObject private var store = WeatherAttributionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Grows with the reader's text size. Apple states no minimum, so this is sized to
    /// sit with caption text rather than to be as small as it can get away with.
    @ScaledMetric(relativeTo: .caption) private var markHeight: CGFloat = 15

    /// Where the legal link points before the fetch lands, and if it never does.
    static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    private var markURL: URL? {
        guard let attribution = store.attribution else { return nil }
        return colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
    }

    var body: some View {
        Link(destination: store.attribution?.legalPageURL ?? Self.fallbackLegalURL) {
            if let markURL {
                AsyncImage(url: markURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        wordmark
                    }
                }
                .frame(height: markHeight)
            } else {
                wordmark
            }
        }
        .accessibilityLabel("Weather data from Apple Weather")
        .accessibilityHint("Opens the list of weather data sources")
        .task { await store.loadIfNeeded() }
    }

    /// The trademark in words, for the moment before the image arrives and for the case
    /// where it never does. Apple's own name for the mark, not a description of it.
    private var wordmark: some View {
        Text("Apple Weather")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The weather data source attributions, in full.
///
/// `legalAttributionText` is what Apple hands over for this, and it is shown word for
/// word: it is a legal notice, so it is not summarised, trimmed or reworded. The legal
/// page itself is one tap away underneath it.
struct WeatherDataSourcesView: View {
    @ObservedObject private var store = WeatherAttributionStore.shared

    var body: some View {
        List {
            Section {
                if let attribution = store.attribution {
                    Text(attribution.legalAttributionText)
                        .font(.footnote)
                        .textSelection(.enabled)
                } else {
                    Text("Fetching the weather data sources. This needs a connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data sources")
            } footer: {
                Text("HydroDrop's hot day suggestions use Apple Weather. These are the sources behind it.")
            }

            Section {
                Link(destination: store.attribution?.legalPageURL ?? WeatherAttributionLink.fallbackLegalURL) {
                    Label("Open the full attribution page", systemImage: "safari")
                }
            }
        }
        .navigationTitle("Apple Weather")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadIfNeeded() }
    }
}
