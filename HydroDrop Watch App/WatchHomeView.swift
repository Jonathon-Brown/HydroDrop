import SwiftUI

struct WatchHomeView: View {
    @StateObject private var session = WatchSessionManager.shared
    @ObservedObject private var store = StoreManager.shared

    private let quickAddPresets = [200, 330, 500]

    private var progress: Double {
        guard session.dailyGoalML > 0 else { return 0 }
        return Double(session.todayTotalML) / Double(session.dailyGoalML)
    }

    var body: some View {
        Group {
            if store.isSubscribed {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .onAppear { session.activate() }
    }

    private var unlockedContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                MascotView(progress: progress, size: 70)

                Text("\(session.measurementSystem.formattedNumber(mL: session.todayTotalML)) / \(session.measurementSystem.format(mL: session.dailyGoalML))")
                    .font(.headline)

                ForEach(quickAddPresets, id: \.self) { amount in
                    Button {
                        session.logDrink(amountML: amount)
                    } label: {
                        Label(session.measurementSystem.format(mL: amount), systemImage: "drop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("HydroDrop+")
                .font(.headline)
            Text("Subscribe on your iPhone to unlock Apple Watch support.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    WatchHomeView()
}
