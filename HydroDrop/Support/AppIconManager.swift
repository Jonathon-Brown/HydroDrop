import UIKit

/// Keeps the Home Screen icon in step with the mascot skin actually on screen.
///
/// Takes the skin the way `AppSettings.activeMascotSkin` computes it — preference
/// gated by the live entitlement — so a lapsed subscription puts the classic icon
/// back on the next launch and a resubscription brings the chosen one back, the same
/// rule the mascot itself follows. No-op when the icon already matches, which is what
/// keeps the system "You have changed the icon" alert from appearing on every launch.
@MainActor
enum AppIconManager {
    static func sync(to skin: MascotSkin) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let wanted = skin.appIconName
        guard app.alternateIconName != wanted else { return }
        app.setAlternateIconName(wanted) { error in
            if let error {
                Diagnostics.log("failed to set app icon \(wanted ?? "primary"): \(error)")
            }
        }
    }
}
