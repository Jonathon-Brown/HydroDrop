import XCTest
@testable import HydroDrop

/// The privacy page says HydroDrop shows no ads, and doesn't start Google's ad software,
/// in the European Economic Area, the UK and Switzerland. That promise rests on this one
/// decision, so every country it names is checked here in both of the forms the app sees.
final class AdRegionTests: XCTestCase {
    /// The EU's 27, the rest of the EEA, the UK and Switzerland, as (two-letter region
    /// setting, three-letter App Store storefront).
    private let region: [(String, String)] = [
        ("AT", "AUT"), ("BE", "BEL"), ("BG", "BGR"), ("HR", "HRV"), ("CY", "CYP"), ("CZ", "CZE"),
        ("DK", "DNK"), ("EE", "EST"), ("FI", "FIN"), ("FR", "FRA"), ("DE", "DEU"), ("GR", "GRC"),
        ("HU", "HUN"), ("IE", "IRL"), ("IT", "ITA"), ("LV", "LVA"), ("LT", "LTU"), ("LU", "LUX"),
        ("MT", "MLT"), ("NL", "NLD"), ("PL", "POL"), ("PT", "PRT"), ("RO", "ROU"), ("SK", "SVK"),
        ("SI", "SVN"), ("ES", "ESP"), ("SE", "SWE"),
        ("IS", "ISL"), ("LI", "LIE"), ("NO", "NOR"),
        ("GB", "GBR"), ("CH", "CHE"),
    ]

    func testEveryCountryInTheRegionShowsNoAdsInEitherForm() {
        XCTAssertEqual(region.count, 32)
        for (twoLetter, threeLetter) in region {
            XCTAssertFalse(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: twoLetter), twoLetter)
            XCTAssertFalse(AdRegion.servesAds(storefrontCountry: threeLetter, deviceRegion: nil), threeLetter)
            XCTAssertFalse(AdRegion.servesAds(storefrontCountry: threeLetter, deviceRegion: twoLetter), threeLetter)
        }
    }

    func testCountriesOutsideTheRegionStillShowAds() {
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: "USA", deviceRegion: "US"))
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: "CAN", deviceRegion: "CA"))
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: "AUS", deviceRegion: "AU"))
        // Not in the EEA, whatever the map suggests.
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: "TUR", deviceRegion: "TR"))
    }

    /// Either signal is enough to switch ads off: a UK account on a phone set to the US,
    /// or a US account on a phone set to Germany, both see none.
    func testEitherSignalInTheRegionIsEnough() {
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: "USA", deviceRegion: "GB"))
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: "GBR", deviceRegion: "US"))
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: "USA", deviceRegion: "DE"))
    }

    /// Knowing nothing shows no ads; knowing one thing outside the region is enough.
    func testItFailsClosedWhenNothingIsKnown() {
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: nil))
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: "", deviceRegion: " "))
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: "US"))
        XCTAssertTrue(AdRegion.servesAds(storefrontCountry: "USA", deviceRegion: nil))
    }

    func testCaseAndSpacingDoNotMatter() {
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: "gbr", deviceRegion: nil))
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: " fr "))
    }

    func testTheRegionSettingForEuropeAsAWholeCountsAsTheRegion() {
        XCTAssertFalse(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: "150"))
    }

    /// EU territories that the region setting names on their own, not as their country.
    func testEUTerritoriesWithTheirOwnCodesCountAsTheRegion() {
        for code in ["RE", "GP", "MQ", "GF", "YT", "MF", "AX", "IC", "EA"] {
            XCTAssertFalse(AdRegion.servesAds(storefrontCountry: nil, deviceRegion: code), code)
        }
    }
}
