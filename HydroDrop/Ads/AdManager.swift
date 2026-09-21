import Foundation
import GoogleMobileAds

/// Central spot for HydroDrop's ad configuration.
///
/// Free-tier users see an anchored adaptive banner on Today and History.
/// HydroDrop+ subscribers never see ads — see the `!store.isSubscribed`
/// checks in HomeView/HistoryView, and "No ads, ever" in PaywallView's
/// feature list.
enum AdManager {
    /// HydroDrop's real AdMob banner ad unit ID, used in release builds.
    ///
    /// Created at admob.google.com → Apps → HydroDrop → Ad units → Banner.
    /// The DEBUG branch keeps Google's public test unit in local/simulator
    /// builds so you never risk serving (or accidentally clicking) live ads
    /// while developing — doing that on your own device is one of the
    /// fastest ways to get an AdMob account flagged for invalid traffic.
    static var bannerAdUnitID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/2435281174"
        #else
        return "ca-app-pub-5814718978331211/5842312557"
        #endif
    }

    /// Call once at launch, before any ad is requested.
    static func start() {
        MobileAds.shared.start(completionHandler: nil)
    }

    /// The only place an ad request is made. Every one asks for non-personalized ads.
    ///
    /// `npa=1` tells Google to choose the ad from context, such as the app and a rough
    /// region, and not from a profile of the person. HydroDrop does not ask for
    /// permission to track either, so iOS never hands over the advertising identifier.
    /// That is what makes `NSPrivacyTracking` false in the privacy manifest true, and it
    /// is why there is no tracking alert on first run. A new ad format has to get its
    /// request from here too; `Scripts/preflight.sh` fails on a bare `Request()`.
    static func makeRequest() -> Request {
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = nonPersonalizedParameters
        request.register(extras)
        return request
    }

    static let nonPersonalizedParameters = ["npa": "1"]
}
