import Foundation

/// Decides when to ask for an App Store review.
///
/// The ask is tied to reaching a week-long streak: the moment the app has visibly
/// done its job. It is made at most once per app version, and never from inside
/// onboarding or a purchase, which `HomeView` enforces at the call site because only
/// it knows what is on screen. The system further throttles the prompt on its own
/// terms, so even a positive answer here is a request, not a guarantee.
enum ReviewPrompter {
    static let streakThreshold = 7
    private static let lastPromptedVersionKey = "review.lastPromptedVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func shouldPrompt(
        streak: Int,
        version: String = currentVersion,
        defaults: UserDefaults = .standard
    ) -> Bool {
        streak >= streakThreshold && defaults.string(forKey: lastPromptedVersionKey) != version
    }

    static func markPrompted(version: String = currentVersion, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: lastPromptedVersionKey)
    }
}
