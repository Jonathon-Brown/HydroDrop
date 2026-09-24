import SwiftUI
import StoreKit

/// Raw `EventCounter` tallies for this device, reached by long-pressing the version at
/// the foot of Settings. Read-only on purpose: it exists so the developer can check their own
/// phone, and there is nothing to send or export.
struct EventCountsView: View {
    @Environment(\.dismiss) private var dismiss

    /// DEBUG builds, plus anything StoreKit reports as running in the sandbox — which is
    /// where TestFlight builds run. Release is the only configuration TestFlight ever
    /// installs, so a `#if DEBUG` gate alone would hide this from the one device it is for.
    ///
    /// The payload is read without verification: this gates a read-only diagnostics screen,
    /// not an entitlement, and a failed verification shouldn't lock the developer out of it.
    static var isAvailable: Bool {
        get async {
            #if DEBUG
            return true
            #else
            guard let result = try? await AppTransaction.shared else { return false }
            return result.unsafePayloadValue.environment == .sandbox
            #endif
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Paywall shown") {
                    ForEach(PaywallSource.allCases) { source in
                        row(source.rawValue, .paywallShown(source))
                    }
                    LabeledContent("total", value: "\(totalShown)")
                        .font(.body.weight(.semibold))
                }

                Section("Paywall outcome") {
                    row("dismissed without purchase", .paywallDismissedWithoutPurchase)
                    row("purchase attempted", .purchaseAttempted)
                    row("purchase succeeded", .purchaseSucceeded)
                    row("purchase cancelled", .purchaseCancelled)
                    row("purchase pending", .purchasePending)
                    row("purchase failed", .purchaseFailed)
                }

                Section {
                    row("streak-break message shown", .streakBreakMessageShown)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Paywall counts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var totalShown: Int {
        PaywallSource.allCases.reduce(0) { $0 + EventCounter.count(of: .paywallShown($1)) }
    }

    private var footerText: String {
        let since = EventCounter.countingSince()
            .map { "Counting since \($0.formatted(date: .abbreviated, time: .shortened))." }
            ?? "Nothing recorded yet."
        return "\(since) Stored only on this device and never sent anywhere."
    }

    private func row(_ title: String, _ event: EventCounter.Event) -> some View {
        LabeledContent(title, value: "\(EventCounter.count(of: event))")
            .font(.body.monospacedDigit())
    }
}

#Preview {
    EventCountsView()
}
