#if DUO_V2
import CoreImage
import XCTest
@testable import HydroDrop

/// Stage J: the QR code the invite and reconnect sheets draw. Each is read back with Core Image's
/// own detector, which runs headless in a unit test, so a code that a camera could not read, or
/// that reads as something else, fails here.
@MainActor
final class DuoQRCodeTests: XCTestCase {
    private let link = "https://hydrodrop.us/duo#H7K39QWX.ABCDEFGHJKMNPQRSTVWXYZ0123"
    private let reconnectLink = "https://hydrodrop.us/duo#R3C0NN3C"

    /// What a detector reads in `image`, and the error correction level it found.
    private func read(_ image: UIImage) -> [(message: String?, level: CIQRCodeDescriptor.ErrorCorrectionLevel?)] {
        guard let cgImage = image.cgImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        return detector.features(in: CIImage(cgImage: cgImage)).compactMap { feature in
            guard let qr = feature as? CIQRCodeFeature else { return nil }
            return (qr.messageString, qr.symbolDescriptor?.errorCorrectionLevel)
        }
    }

    /// The pixel sizes the sheets use: a 240-point code on 1x, 2x and 3x screens.
    private func scalesTheSheetsUse(for text: String) throws -> [Int] {
        let modules = try XCTUnwrap(DuoQRCode.modules(for: text))
        return [1, 2, 3].map { DuoQRCode.pixelsPerModule(for: modules, points: DuoCodeDisplay.qrPoints, displayScale: $0) }
    }

    /// One byte per pixel, the first row the top, whatever the image's own layout.
    private func grayPixels(_ image: UIImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 128, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .none
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, bytes)
    }

    // MARK: - It reads back as exactly what it was given

    func testTheLinkWithItsSecretReadsBackExactlyAtEverySizeTheSheetsUse() throws {
        for scale in try scalesTheSheetsUse(for: link) {
            let image = try XCTUnwrap(DuoQRCode.image(for: link, scale: scale), "scale \(scale)")
            let found = read(image)
            XCTAssertEqual(found.count, 1, "one code at scale \(scale)")
            XCTAssertEqual(found.first?.message, link, "scale \(scale)")
            XCTAssertEqual(found.first?.level, .levelM, "error correction level M (scale \(scale))")
        }
    }

    func testABareCodeAndALinkWithNoSecretReadBackExactly() throws {
        for text in ["H7K39QWX", "H7K3-9QWX", reconnectLink] {
            for scale in try scalesTheSheetsUse(for: text) {
                let image = try XCTUnwrap(DuoQRCode.image(for: text, scale: scale))
                XCTAssertEqual(read(image).map(\.message), [text], "\(text) at scale \(scale)")
                XCTAssertEqual(read(image).first?.level, .levelM)
            }
        }
    }

    func testTwoCodesMakeTwoDifferentPictures() throws {
        let one = try XCTUnwrap(DuoQRCode.modules(for: link))
        let other = try XCTUnwrap(DuoQRCode.modules(for: "https://hydrodrop.us/duo#H7K39QWY.ABCDEFGHJKMNPQRSTVWXYZ0123"))
        XCTAssertNotEqual(one, other)
    }

    // MARK: - The picture itself

    func testThePictureIsBlackAndWhiteWithAFourModuleQuietZoneAtEverySizeTheSheetsUse() throws {
        let modules = try XCTUnwrap(DuoQRCode.modules(for: link))
        // 60 bytes at level M is version 4, 33 modules square.
        XCTAssertEqual(modules.side, 33)
        XCTAssertEqual(modules.sideWithQuietZone, 41)
        for scale in try scalesTheSheetsUse(for: link) {
            let image = try XCTUnwrap(DuoQRCode.image(for: link, scale: scale))
            XCTAssertEqual(image.scale, 1)
            let pixels = try grayPixels(image)
            XCTAssertEqual(pixels.width, 41 * scale)
            XCTAssertEqual(pixels.height, 41 * scale)
            XCTAssertEqual(Set(pixels.bytes), [0, 255], "only black and white, no grey edges (scale \(scale))")
            let margin = DuoQRCode.quietZone * scale
            for row in 0..<pixels.height {
                for column in 0..<pixels.width where row < margin || row >= pixels.height - margin || column < margin || column >= pixels.width - margin {
                    guard pixels.bytes[row * pixels.width + column] == 255 else {
                        return XCTFail("the quiet zone is not white at (\(column), \(row)), scale \(scale)")
                    }
                }
            }
            // Every module is a whole block of `scale` pixels of one colour, matching the modules.
            for row in 0..<modules.side {
                for column in 0..<modules.side {
                    let expected: UInt8 = modules.isDark(row: row, column: column) ? 0 : 255
                    for y in [0, scale - 1] {
                        for x in [0, scale - 1] {
                            let pixel = pixels.bytes[(margin + row * scale + y) * pixels.width + margin + column * scale + x]
                            guard pixel == expected else { return XCTFail("module (\(column), \(row)) is not one solid block at scale \(scale)") }
                        }
                    }
                }
            }
        }
    }

    /// A code drawn upside down or mirrored can still look like a QR code, and some readers turn it
    /// back, but not every camera does: the three finder patterns must be top left, top right and
    /// bottom left, and only there.
    func testTheFinderPatternsAreInTheirThreeCornersSoTheCodeIsNotMirrored() throws {
        let modules = try XCTUnwrap(DuoQRCode.modules(for: link))
        let n = modules.side
        func isFinder(top: Int, left: Int) -> Bool {
            for row in 0..<7 {
                for column in 0..<7 {
                    let ring = max(abs(row - 3), abs(column - 3))
                    if modules.isDark(row: top + row, column: left + column) != (ring != 2) { return false }
                }
            }
            return true
        }
        XCTAssertTrue(isFinder(top: 0, left: 0), "top left")
        XCTAssertTrue(isFinder(top: 0, left: n - 7), "top right")
        XCTAssertTrue(isFinder(top: n - 7, left: 0), "bottom left")
        XCTAssertFalse(isFinder(top: n - 7, left: n - 7), "nothing in the bottom right")

        // And the image keeps that orientation: its top-left finder's centre is dark, the light
        // ring around it light, and the same in the other two corners.
        let scale = 10
        let pixels = try grayPixels(try XCTUnwrap(DuoQRCode.image(of: modules, scale: scale)))
        func pixel(row: Int, column: Int) -> UInt8 {
            let margin = DuoQRCode.quietZone * scale
            return pixels.bytes[(margin + row * scale + scale / 2) * pixels.width + margin + column * scale + scale / 2]
        }
        for (top, left) in [(0, 0), (0, n - 7), (n - 7, 0)] {
            XCTAssertEqual(pixel(row: top + 3, column: left + 3), 0)
            XCTAssertEqual(pixel(row: top + 1, column: left + 1), 255)
            XCTAssertEqual(pixel(row: top, column: left), 0)
        }
    }

    /// Correctness L9, mutant Q10: a symbol turned about its diagonal keeps its three finder
    /// patterns where they belong and still reads with Core Image's detector, but not with every
    /// camera. So the modules of one fixed code, and the picture drawn from them, must be exactly
    /// these, row by row from the top (level M, version 1, as Core Image encodes it).
    private static let goldenH7K39QWX = [
        "#######.##....#######",
        "#.....#.#.#...#.....#",
        "#.###.#.#..##.#.###.#",
        "#.###.#..#..#.#.###.#",
        "#.###.#.##..#.#.###.#",
        "#.....#....##.#.....#",
        "#######.#.#.#.#######",
        "..........###........",
        "#..#######..##..#.###",
        ".#####.####.#.#.###.#",
        "....###.##...##.#..##",
        ".#.#....#..#.....##..",
        "..#.#.###.#...#..####",
        "........#.###....#...",
        "#######.###.#####..#.",
        "#.....#.##.###..###.#",
        "#.###.#.#..##.####.##",
        "#.###.#.#..##...##...",
        "#.###.#.......###..##",
        "#.....#...#..##.##.#.",
        "#######.#..#.......#.",
    ]

    func testAFixedCodeIsExactlyTheseModulesNeitherMirroredNorTurned() throws {
        let golden = Self.goldenH7K39QWX
        let modules = try XCTUnwrap(DuoQRCode.modules(for: "H7K39QWX"))
        XCTAssertEqual(modules.side, golden.count)
        let rows = (0..<modules.side).map { row in
            String((0..<modules.side).map { modules.isDark(row: row, column: $0) ? "#" : "." })
        }
        XCTAssertEqual(rows, golden, "the modules, row by row")
        let transposed = (0..<golden.count).map { column in String(golden.map { Array($0)[column] }) }
        XCTAssertNotEqual(transposed, golden, "the golden symbol is not its own mirror, so the check above can tell")

        // And the picture: the centre of every module is the colour the golden symbol says.
        let scale = 7
        let pixels = try grayPixels(try XCTUnwrap(DuoQRCode.image(for: "H7K39QWX", scale: scale)))
        let margin = DuoQRCode.quietZone * scale
        let drawn = (0..<golden.count).map { row in
            String((0..<golden.count).map { column -> Character in
                pixels.bytes[(margin + row * scale + scale / 2) * pixels.width + margin + column * scale + scale / 2] == 0 ? "#" : "."
            })
        }
        XCTAssertEqual(drawn, golden, "the picture, row by row")
    }

    func testNothingIsMadeForNothingOrForTooMuchOrAtAnAbsurdSize() {
        XCTAssertNil(DuoQRCode.image(for: ""))
        XCTAssertNil(DuoQRCode.modules(for: String(repeating: "A", count: 5_000)), "longer than any QR code holds")
        XCTAssertNil(DuoQRCode.image(for: link, scale: 0))
        XCTAssertNil(DuoQRCode.image(for: link, scale: -3))
        XCTAssertNil(DuoQRCode.image(for: link, scale: 65))
        XCTAssertNotNil(DuoQRCode.image(for: link, scale: 64))
        XCTAssertNotNil(DuoQRCode.image(for: link), "the default size")
    }

    func testTheSheetsSizeIsWholePixelsPerModuleAndAboutTheSizeAsked() throws {
        let modules = try XCTUnwrap(DuoQRCode.modules(for: link))
        for displayScale in [1.0, 2.0, 3.0] {
            let perModule = DuoQRCode.pixelsPerModule(for: modules, points: DuoCodeDisplay.qrPoints, displayScale: displayScale)
            let points = CGFloat(modules.sideWithQuietZone * perModule) / displayScale
            XCTAssertLessThanOrEqual(points, DuoCodeDisplay.qrPoints, "never wider than asked (\(displayScale)x)")
            XCTAssertGreaterThan(points, DuoCodeDisplay.qrPoints * 0.8, "and not much smaller (\(displayScale)x)")
        }
        XCTAssertEqual(DuoQRCode.pixelsPerModule(for: modules, points: 1, displayScale: 1), 1, "never less than a pixel")
        XCTAssertEqual(DuoQRCode.pixelsPerModule(for: modules, points: 100_000, displayScale: 3), 64, "never absurdly large")
    }
}
#endif
