import XCTest
@testable import HydroCore

final class DuoStrictLinkTests: XCTestCase {
    func testAuthorityDecorationsAndEncodedPathsAreNotOurLinks() throws {
        for text in ["https://name@hydrodrop.us/duo#H7K39QWX",
                     "https://name:secret@hydrodrop.us/duo#H7K39QWX",
                     "https://hydrodrop.us:443/duo#H7K39QWX",
                     "https://hydrodrop.us:8443/duo#H7K39QWX",
                     "https://hydrodrop.us:/duo#H7K39QWX",
                     "https://%68ydrodrop.us/duo#H7K39QWX",
                     "https://hydrodrop.us/duo#%487K39QWX",
                     "https://hydrodrop.us/%64uo#H7K39QWX",
                     "https://hydrodrop.us/duo/#H7K39QWX"] {
            XCTAssertNil(DuoLink.parse(try XCTUnwrap(URL(string: text))), text)
            XCTAssertNil(DuoInviteCode.parse(pasted: text), text)
        }
    }

    func testCanonicalLinksStillRoundTripWithAndWithoutASecret() throws {
        for secret: String? in [nil, String(repeating: "A", count: 26)] {
            let url = try XCTUnwrap(DuoLink.url(code: "H7K39QWX", k: secret))
            XCTAssertEqual(DuoLink.parse(url), DuoParsedInvite(code: "H7K39QWX", k: secret))
        }
        XCTAssertEqual(DuoLink.parse(try XCTUnwrap(URL(string: "HTTPS://HYDRODROP.US/duo#h7k39qwx")))?.code, "H7K39QWX")
    }
}
