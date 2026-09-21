import AppIntents
import Foundation
import SwiftData

/// The unit an amount was given in, so a saved shortcut keeps meaning what it meant.
///
/// Without this the number in a shortcut would be read in whichever units HydroDrop
/// happens to be set to, and "log 16" would quietly change from 16 oz to 16 mL the day
/// the user switched. The unit travels with the shortcut instead.
enum VolumeUnitChoice: String, AppEnum {
    case milliliters
    case fluidOunces

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Unit")

    static var caseDisplayRepresentations: [VolumeUnitChoice: DisplayRepresentation] = [
        .milliliters: "mL",
        .fluidOunces: "fl oz",
    ]

    var measurementSystem: MeasurementSystem {
        switch self {
        case .milliliters: return .metric
        case .fluidOunces: return .imperial
        }
    }
}

/// Logs a drink without opening the app.
///
/// Runs from Siri, the Shortcuts app, the Action Button and the widget's quick-add
/// button, so it can be running in an extension process with no UI of its own. Every
/// failure therefore has to come back as something a person hears or reads.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Water"

    static var description = IntentDescription(
        "Adds a drink to today's total in HydroDrop. Leave the amount empty to log your first quick-add size.",
        categoryName: "Logging"
    )

    /// Deliberately false. The whole point is to log a glass from the Action Button or
    /// the Home Screen without the app taking over the display.
    static var openAppWhenRun = false

    @Parameter(title: "Amount")
    var amount: Double?

    @Parameter(title: "Unit")
    var unit: VolumeUnitChoice?

    @Parameter(title: "Drink")
    var drink: DrinkTypeChoice?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) \(\.$unit) of \(\.$drink)")
    }

    init() {}

    /// Used by the widget's quick-add button, which knows exactly what it is logging.
    init(amountML: Int) {
        self.amount = Double(amountML)
        self.unit = .milliliters
        self.drink = .water
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = WidgetBridge.currentSnapshot()
        let amountML = try resolvedAmountML(snapshot: snapshot)
        let drinkType = (drink ?? .water).drinkType

        guard let container = SharedModelContainer.makeForExtension() else {
            throw LogWaterError.storeUnavailable
        }
        let context = ModelContext(container)
        // The core rather than `logInApp`: this can be running inside the widget
        // extension, where the reminder scheduler, the watch session and the app's
        // settings do not exist. `afterLogInApp` below is what picks the rest up on
        // the occasions the intent is running in the app instead.
        let saved: DrinkLogger.Logged
        do {
            saved = try DrinkLogger.log(
                amountML: amountML,
                drinkType: drinkType,
                in: context,
                loggedBy: "an intent"
            )
        } catch {
            throw LogWaterError.couldNotSave
        }

        // Read back from the store rather than added to the snapshot, so a drink
        // logged in the app a moment ago is included rather than overwritten.
        let todayTotal = saved.todayTotalML
        var updated = snapshot.resolved()
        updated.todayTotalML = todayTotal
        WidgetBridge.publish(updated)

        let system = snapshot.measurementSystem
        let logged = system.format(mL: amountML)
        let remaining = max(0, snapshot.dailyGoalML - todayTotal)
        let dialog: IntentDialog = remaining > 0
            ? "Logged \(logged). \(system.format(mL: remaining)) to go."
            : "Logged \(logged). You have reached your goal for today."
        return .result(dialog: dialog)
    }

    private func resolvedAmountML(snapshot: HydrationSnapshot) throws -> Int {
        guard let amount else {
            return snapshot.quickAddPresetsML.first ?? 250
        }
        guard amount.isFinite, amount > 0 else { throw LogWaterError.implausibleAmount }
        let system = (unit ?? (snapshot.measurementSystem == .imperial ? .fluidOunces : .milliliters)).measurementSystem
        let amountML = system.mL(fromDisplayVolume: amount)
        guard MeasurementSystem.plausibleDrinkRangeML.contains(amountML) else {
            throw LogWaterError.implausibleAmount
        }
        return amountML
    }
}

/// The drink types, as something Shortcuts can offer in a menu.
enum DrinkTypeChoice: String, AppEnum {
    case water, coffee, tea, sparkling, juice, other

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drink")

    static var caseDisplayRepresentations: [DrinkTypeChoice: DisplayRepresentation] = [
        .water: "Water",
        .coffee: "Coffee",
        .tea: "Tea",
        .sparkling: "Sparkling water",
        .juice: "Juice",
        .other: "Other",
    ]

    var drinkType: DrinkType {
        DrinkType(rawValue: rawValue) ?? .water
    }
}

enum LogWaterError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable
    case couldNotSave
    case implausibleAmount

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable:
            return "Open HydroDrop once so it can finish setting up, then try again."
        case .couldNotSave:
            return "HydroDrop could not save that drink. Try again in a moment."
        case .implausibleAmount:
            return "That is not an amount HydroDrop can log. Try something between a sip and five litres."
        }
    }
}
