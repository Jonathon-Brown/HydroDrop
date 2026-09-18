import AppIntents
import Foundation

/// Reports how today is going, without opening the app.
///
/// The spoken answer uses whichever units the user reads HydroDrop in. The returned
/// value is always in millilitres, because a shortcut that feeds this into something
/// else needs a number whose meaning does not change when a setting does.
struct GetTodayProgressIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Hydration"

    static var description = IntentDescription(
        "Reports how much you have had today and how much is left. The returned value is in millilitres.",
        categoryName: "Logging"
    )

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let snapshot = WidgetBridge.currentSnapshot()
        let system = snapshot.measurementSystem
        let total = snapshot.todayTotalML
        let remaining = max(0, snapshot.dailyGoalML - total)

        let dialog: IntentDialog
        if remaining > 0 {
            dialog = "You have had \(system.format(mL: total)) of your \(system.format(mL: snapshot.dailyGoalML)) goal. \(system.format(mL: remaining)) to go."
        } else {
            dialog = "You have had \(system.format(mL: total)) today and reached your goal."
        }
        return .result(value: total, dialog: dialog)
    }
}
