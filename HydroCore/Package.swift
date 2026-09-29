// swift-tools-version: 5.9

// HydroCore holds the rules that more than one app has to agree on: day keys, and the
// Duo Streaks rules (which days count, what is shared, nudges and their limits, quiet
// hours). It imports nothing but Foundation, so the same rules can be ported to the
// Android app and the Duo server and checked against one set of test vectors.
//
// macOS is listed only so that `swift test` runs on the Mac; no macOS app uses it.
import PackageDescription

let package = Package(
    name: "HydroCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v13),
    ],
    products: [
        .library(name: "HydroCore", targets: ["HydroCore"]),
    ],
    targets: [
        .target(name: "HydroCore"),
        // The shared vectors file ships inside the test bundle, because Xcode Cloud runs
        // tests on a machine that has the built bundle but not the source checkout.
        .testTarget(
            name: "HydroCoreTests",
            dependencies: ["HydroCore"],
            path: "Tests",
            sources: ["HydroCoreTests"],
            resources: [.copy("Vectors")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
