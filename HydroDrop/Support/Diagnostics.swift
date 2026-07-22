import UIKit

enum Diagnostics {
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
