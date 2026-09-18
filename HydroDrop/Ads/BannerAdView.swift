import SwiftUI
import GoogleMobileAds

/// A SwiftUI-hosted Google Mobile Ads anchored adaptive banner.
///
/// Sizes itself to the available width and reports its own height back
/// once an ad loads, so callers don't need to hardcode a banner height
/// (adaptive banners can be taller than the classic 50pt on some devices).
/// Only place this behind a `!store.isSubscribed` check — HydroDrop+
/// subscribers should never see it.
struct BannerAdView: View {
    let adUnitID: String
    @State private var adHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geometry in
            BannerViewRepresentable(adUnitID: adUnitID, width: geometry.size.width, adHeight: $adHeight)
        }
        .frame(height: adHeight)
    }
}

private struct BannerViewRepresentable: UIViewRepresentable {
    let adUnitID: String
    let width: CGFloat
    @Binding var adHeight: CGFloat

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = adUnitID
        banner.rootViewController = Self.rootViewController()
        banner.delegate = context.coordinator
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(adHeight: $adHeight)
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        @Binding var adHeight: CGFloat

        init(adHeight: Binding<CGFloat>) {
            _adHeight = adHeight
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            adHeight = bannerView.adSize.size.height
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            // Leave the placeholder height — the space just stays empty for this load.
        }
    }
}
