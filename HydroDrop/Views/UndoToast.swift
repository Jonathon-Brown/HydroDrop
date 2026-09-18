import SwiftUI

/// The short-lived "logged, tap to undo" bar shown after a drink is added.
///
/// Deliberately not an alert: logging water is a one-tap action and confirming it
/// would cost more taps than the mistake does. The toast takes the place of that
/// confirmation, so it has to stay out of the way and go away on its own.
struct UndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.22)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.95))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    UndoToast(message: "Logged 500 mL") {}
}
