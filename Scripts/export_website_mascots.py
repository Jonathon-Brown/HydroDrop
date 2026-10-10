#!/usr/bin/env python3
"""Export the actual SwiftUI mascot for the static site. Requires macOS and Xcode."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
# Only Xcode previews are omitted; the production view is compiled unchanged.
source = (repo / "HydroDrop/Views/MascotView.swift").read_text().split("// MARK: - Previews")[0]
main = r'''
import AppKit
import SwiftUI
@main struct ExportMascots {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for skin in MascotSkin.allCases {
            for (index, progress) in [0.0, 0.3, 0.6, 0.9, 1.1].enumerated() {
                if skin != .classic && index != 4 { continue }
                let renderer = ImageRenderer(content: MascotView(progress: progress, size: 300, skin: skin, isAnimated: false).padding(36).environment(\.colorScheme, .light))
                renderer.scale = 2
                guard let image = renderer.cgImage else { fatalError("No rendered image") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(skin.rawValue)-\(index).png"))
            }
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hydrodrop-mascots-") as directory:
    work = Path(directory)
    (work / "MascotView.swift").write_text(source)
    (work / "Export.swift").write_text(main)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(repo / "HydroDrop/Models/MascotSkin.swift"), str(work / "MascotView.swift"), str(work / "Export.swift"), "-o", str(work / "export")], check=True)
    subprocess.run([str(work / "export"), str(repo / "docs/assets/mascots")], check=True)
