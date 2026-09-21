import XCTest
import GoogleMobileAds
@testable import HydroDrop

/// The privacy manifest says HydroDrop does not track, and the privacy page says its ads
/// are non-personalized. Both are promises about what is inside an ad request, so this
/// looks inside one.
final class AdRequestTests: XCTestCase {
    func testEveryAdRequestAsksForNonPersonalizedAds() throws {
        let request = AdManager.makeRequest()
        let extras = try XCTUnwrap(request.adNetworkExtras(for: Extras.self) as? Extras, "the request carries no extras at all")
        XCTAssertEqual(extras.additionalParameters?["npa"] as? String, "1")
    }

    func testTheParameterIsTheOneGoogleDocuments() {
        XCTAssertEqual(AdManager.nonPersonalizedParameters, ["npa": "1"])
    }

    func testTheAppNoLongerCarriesATrackingUsageString() {
        XCTAssertNil(
            Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription"),
            "a tracking usage string means the app can ask to track, which it has promised not to"
        )
    }
}
