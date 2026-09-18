import SwiftUI

/// One piece of paper in the air.
private struct ConfettiPiece {
    let hue: Double
    let startX: Double
    let velocityX: Double
    let velocityY: Double
    let spin: Double
    let phase: Double
    let width: Double
    let height: Double
    let isRound: Bool

    static func burst(count: Int) -> [ConfettiPiece] {
        (0..<count).map { _ in
            ConfettiPiece(
                // Kept off the red end so nothing in a celebration reads as a warning.
                hue: Double.random(in: 0.05...0.75),
                startX: Double.random(in: 0.1...0.9),
                velocityX: Double.random(in: -0.32...0.32),
                // Everything is thrown upwards to begin with; gravity does the rest.
                velocityY: Double.random(in: -1.5 ... -0.85),
                spin: Double.random(in: -5.5...5.5),
                phase: Double.random(in: 0...(.pi * 2)),
                width: Double.random(in: 6...11),
                height: Double.random(in: 9...16),
                isRound: Bool.random()
            )
        }
    }
}

/// A one-shot confetti burst, drawn in SwiftUI.
///
/// A `Canvas` rather than a few dozen animated views: the pieces are simple shapes with
/// no interaction, and drawing them directly keeps one celebration from putting seventy
/// nodes into the view hierarchy.
///
/// Honours Reduce Motion by drawing nothing at all. There is no calmer version of
/// confetti that is still confetti, and the celebration reads perfectly well without it.
struct ConfettiView: View {
    var pieceCount: Int = 70
    var duration: Double = 3.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [ConfettiPiece] = []
    @State private var startDate = Date()

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        draw(in: &canvas, size: size, elapsed: context.date.timeIntervalSince(startDate))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, pieces.isEmpty else { return }
            pieces = ConfettiPiece.burst(count: pieceCount)
            startDate = Date()
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, elapsed: Double) {
        guard elapsed < duration else { return }
        // Fades out over the last second rather than vanishing mid-air.
        let fade = min(1, max(0, (duration - elapsed) / 1.0))
        let gravity = 1.65

        for piece in pieces {
            let x = (piece.startX + piece.velocityX * elapsed) * size.width
            // Launched from just below the top so the burst reads as thrown upward.
            let y = (0.55 + piece.velocityY * elapsed + 0.5 * gravity * elapsed * elapsed) * size.height
            guard y < size.height + 40 else { continue }

            let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
            let path = piece.isRound
                ? Path(ellipseIn: rect)
                : Path(roundedRect: rect, cornerRadius: 1.5)
            // Flutter, then spin: the scale is what sells a flat piece of paper turning
            // edge-on as it falls.
            let flutter = cos(piece.phase + elapsed * 6)
            let transform = CGAffineTransform(translationX: x, y: y)
                .rotated(by: piece.spin * elapsed)
                .scaledBy(x: flutter, y: 1)

            canvas.fill(
                path.applying(transform),
                with: .color(Color(hue: piece.hue, saturation: 0.75, brightness: 0.95, opacity: fade))
            )
        }
    }
}

#Preview {
    ZStack {
        Color(.systemBackground)
        ConfettiView()
    }
}
