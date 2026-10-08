#if DUO_V2
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The QR code of an invite's link, or of a bare code, as the invite and reconnect sheets draw it
/// (final design §4.1: "QR: the same URL", which the iOS Camera opens through the universal link
/// and the in-app scanner reads like a typed code).
///
/// It is made on the phone each time a sheet draws one and handed straight to the view: nothing
/// writes it to disk, to the photo library or to any cache, because the link it carries holds the
/// secret `k`. CoreImage's context is told not to keep intermediates for the same reason.
///
/// The picture is exactly black and white with a white quiet zone of four modules (the QR
/// standard's), and every module is a whole number of pixels: CoreImage draws one pixel per module
/// with a one-module margin of its own, and scaling that with any smoothing greys the edges, which
/// some cameras read badly. So the modules are read off CoreImage's output once and drawn again at
/// the size asked for, with no scaling at all.
enum DuoQRCode {
    /// The white margin around the symbol, in modules.
    static let quietZone = 4

    /// The symbol's modules, row by row from the top, `true` for dark, with no margin: `side`
    /// modules square. Nil for an empty string or one too long for any QR code.
    struct Modules: Equatable {
        let side: Int
        let dark: [Bool]

        func isDark(row: Int, column: Int) -> Bool { dark[row * side + column] }

        /// The picture's side in modules, quiet zone included.
        var sideWithQuietZone: Int { side + 2 * DuoQRCode.quietZone }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// How many symbols have been made since launch: a count, never what they held. The sheets
    /// draw a code's QR once (`DuoQRCache`), not on every redraw, and a test holds them to that.
    private(set) static var symbolsMade = 0

    /// The modules of `text` encoded at error correction level M, as plan P2 asks: it survives a
    /// smudge or a glare on a screen and still fits a link with its secret in a 33-module code.
    static func modules(for text: String) -> Modules? {
        guard !text.isEmpty else { return nil }
        symbolsMade += 1
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else { return nil }

        // One byte per pixel, read the way a bitmap context lays rows out: the first row in memory
        // is the top of the picture.
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.interpolationQuality = .none
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // The symbol is the box around its dark modules: its three finder patterns sit in three of
        // its corners, so the box is exactly the symbol whatever margin CoreImage left around it.
        var top = height, left = width, bottom = -1, right = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 128 {
                top = min(top, row); bottom = max(bottom, row)
                left = min(left, column); right = max(right, column)
            }
        }
        guard bottom >= top, right >= left, bottom - top == right - left else { return nil }
        let side = right - left + 1
        var dark = [Bool](repeating: false, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                dark[row * side + column] = pixels[(top + row) * width + left + column] < 128
            }
        }
        return Modules(side: side, dark: dark)
    }

    /// The QR code of `text`, `scale` pixels to a module, as a UIImage of scale 1 (one point per
    /// pixel; the view sizes it). Nil for an empty string or one too long for a QR code.
    static func image(for text: String, scale: Int = 8) -> UIImage? {
        guard let modules = modules(for: text) else { return nil }
        return image(of: modules, scale: scale)
    }

    static func image(of modules: Modules, scale: Int) -> UIImage? {
        // A module of 64 pixels already makes a picture several thousand pixels square.
        guard (1...64).contains(scale) else { return nil }
        let pixelSide = modules.sideWithQuietZone * scale
        var pixels = [UInt8](repeating: 255, count: pixelSide * pixelSide)
        let offset = quietZone * scale
        for row in 0..<modules.side {
            for column in 0..<modules.side where modules.isDark(row: row, column: column) {
                for y in 0..<scale {
                    let start = (offset + row * scale + y) * pixelSide + offset + column * scale
                    for x in 0..<scale { pixels[start + x] = 0 }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: pixelSide, height: pixelSide, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pixelSide,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    /// The pixels per module that make a code about `points` wide on a screen of `displayScale`,
    /// so that each module is a whole number of the screen's own pixels and the picture is drawn
    /// one to one, never resampled.
    static func pixelsPerModule(for modules: Modules, points: CGFloat, displayScale: CGFloat) -> Int {
        let target = points * max(displayScale, 1)
        return max(1, min(64, Int(target / CGFloat(modules.sideWithQuietZone))))
    }
}
#endif
