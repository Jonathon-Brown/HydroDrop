import UIKit
import os

enum Diagnostics {
    private static let logger = Logger(subsystem: "com.jonathonbrown.HydroDrop", category: "app")

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static var summary: String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return """
        ---
        App version: \(appVersion) (\(build))
        iOS version: \(device.systemVersion)
        Device: \(device.model)
        """
    }
}
