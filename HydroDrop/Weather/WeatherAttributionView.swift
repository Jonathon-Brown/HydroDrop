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
/// WeatherKit: the hot-day suggestion in `WeatherBumpCard`, the badge explaining a
/// raised goal in `WeatherBumpBadge`, and the World's sky while it draws a reading, on
/// Today and on Your World (`WorldWeatherAttribution`).
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
/// shown anyway, in Settings under Apple Weather: see `WeatherDataSourcesView`.
struct WeatherAttributionLink: View {
    @ObservedObject private var store = WeatherAttributionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Grows with the reader's text size. Apple states no minimum, so this is sized to
    /// sit with caption text rather than to be as small as it can get away with.
    @ScaledMetric(relativeTo: .caption) private var markHeight: CGFloat = 15

    /// On the World's painted sky rather than in ordinary content. Only
    /// `WorldWeatherAttribution` sets it, together with the colour scheme it needs.
    var onSky = false
    /// How much black is laid over the frost on the sky, for a chip over pale cloud or a
    /// pale snowy sky. Nothing by default.
    var skyShade: Double = 0

    /// Where the legal link points before the fetch lands, and if it never does.
    static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    private var markURL: URL? {
        guard let attribution = store.attribution else { return nil }
        return colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
    }

    var body: some View {
        Link(destination: store.attribution?.legalPageURL ?? Self.fallbackLegalURL) {
            if onSky {
                // The frost is part of the label because a Link only takes taps on its
                // label: padding added from outside would draw a bigger chip without
                // making it any easier to hit. The tap area is 40pt tall, like the gear
                // beside it on Today.
                mark
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(.black.opacity(skyShade))
                        }
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            } else {
                mark
            }
        }
        .accessibilityLabel("Weather data from Apple Weather")
        .accessibilityHint("Opens the list of weather data sources")
        .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private var mark: some View {
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

    /// The trademark in words, for the moment before the image arrives and for the case
    /// where it never does. Apple's own name for the mark, not a description of it.
    private var wordmark: some View {
        Text("Apple Weather")
            .font(.caption2)
            // On the frost the words have to be as bright as the gear and the streak. A
            // concrete colour, because inside a Link a hierarchical `.primary` resolves
            // against the tint and would turn them accent blue, nearly invisible on the
            // day frost (the Settings rows work around the same thing).
            .foregroundStyle(onSky ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
            // On the sky the chip shares a row with the title and the gear, and a second
            // line would make the header taller. Shrinking keeps the whole name on one.
            .lineLimit(onSky ? 1 : nil)
            .minimumScaleFactor(onSky ? 0.5 : 1)
    }
}

/// The Apple Weather mark on the World's painted sky, on Today and on Your World, shown
/// while that sky is drawing a reading: cloudy, rain or snow (`WorldWeather.isOvercast`).
/// A clear reading paints the same sky as none, so it carries no mark, and
/// Settings > Apple Weather stays the place that always has one.
///
/// That sky follows the clock, not light or dark mode, so a phone in light mode at night
/// has a near-black sky behind the mark. The mark is therefore always the one made for
/// dark backgrounds, on the same dark frost as the Today header's gear and streak. The
/// black mark measured about 1.2:1 against the night sky. Plain frost left the white one
/// about 4.3:1 on Today under a pale snowy sky and nearer 3:1 over the paler cloud on Your
/// World, so both add `shade`, Your World more of it; with that, every sky measured
/// 5.1:1 or better by day and 12:1 or better by night. The scheme is forced here,
/// from outside the link, so the link's own `colorScheme` read sees it and no call site
/// can forget it. Text size is capped so the chip fits beside the title and the gear,
/// and the large content viewer shows the name at the sizes above the cap.
struct WorldWeatherAttribution: View {
    /// Passed to the link's `skyShade`: a little on Today, for a pale snowy sky, and more on
    /// Your World, for the paler cloud in its corner.
    var shade: Double = 0

    var body: some View {
        WeatherAttributionLink(onSky: true, skyShade: shade)
            .environment(\.colorScheme, .dark)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer {
                Text("Apple Weather")
            }
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
            // The mark and the legal link together, on a screen that is always reachable
            // whatever the weather and whether or not anyone has subscribed. The card on
            // Today and the World's sky carry them too, but only for a subscriber on a hot
            // or an overcast day, which is not something a reviewer can be relied on to
            // reach.
            Section {
                WeatherAttributionLink()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }

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
                Text("HydroDrop's hot day suggestions and the weather in your world use Apple Weather. These are the sources behind it.")
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
