#if DUO_V2
import Foundation

/// What the build says about itself and where it talks. One file, so preflight can check the
/// server's address is written here and nowhere else (plan P2 item 2, preflight check 1).
enum DuoConfig {
    /// The server's base URL: the staging server for a Debug build, the production one for
    /// every other. A TestFlight build is a Release build, so it talks to production, with
    /// production APNs tokens (final design §6.0, §9.1).
    static let baseURL: URL = {
        #if DEBUG
        return URL(string: "https://api-staging.hydrodrop.us/v1")!
        #else
        return URL(string: "https://api.hydrodrop.us/v1")!
        #endif
    }()

    /// `ios/2.0 (57)` and `2.0 (57)`: the marketing version and the build number.
    static var client: DuoClientInfo {
        client(info: Bundle.main.infoDictionary, arguments: ProcessInfo.processInfo.arguments)
    }

    /// The same, from what it is given, so a test can say what the bundle and the launch
    /// arguments hold.
    ///
    /// A Debug build may claim another marketing version with `-DuoClientVersion 2.0`. The
    /// servers answer `426 upgrade_required` to every write from a client older than their
    /// `MIN_CLIENT_IOS`, which is 2.0 on staging as on production, and this branch still says
    /// 1.8.1 until Jonathon bumps it for the first Duo TestFlight build, so without the override
    /// the first Create tap of the two-simulator staging loop would be refused. Compiled out of
    /// Release: a build that ships can only ever say what it is. The build number is never
    /// overridden, and a value that is not `N.N` or `N.N.N` is ignored (the header's grammar).
    static func client(info: [String: Any]?, arguments: [String]) -> DuoClientInfo {
        var version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        #if DEBUG
        if let flag = arguments.firstIndex(of: "-DuoClientVersion"), arguments.indices.contains(flag + 1),
           arguments[flag + 1].range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil {
            version = arguments[flag + 1]
        }
        #endif
        return DuoClientInfo(marketingVersion: version, build: info?["CFBundleVersion"] as? String ?? "0")
    }

    /// Which APNs the token this build gets belongs to: the sandbox for a build signed for
    /// development (an Xcode install, a simulator), production for TestFlight and the App
    /// Store, whose builds carry no embedded provisioning profile (§6.2: `apns_env`).
    static var apnsEnvironment: DuoAPNsEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil ? .production : .sandbox
        #endif
    }
}
#endif
