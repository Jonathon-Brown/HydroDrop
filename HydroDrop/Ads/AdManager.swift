import Foundation
import GoogleMobileAds
import AppTrackingTransparency

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

    /// Requests App Tracking Transparency authorization if the user hasn't
    /// been asked yet. iOS only ever shows this system prompt once per
    /// install, so it's safe to call this on every launch — it's a no-op
    /// once the user has answered. Call it a couple of seconds after the
    /// UI appears rather than instantly on launch; Apple's own guidance is
    /// to let people see the app is legitimate first. Declining doesn't
    /// block ads — it just means AdMob serves non-personalized ones.
    static func requestTrackingAuthorizationIfNeeded() {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        ATTrackingManager.requestTrackingAuthorization { _ in }
    }
}
