import SwiftUI

/// A simple hand-drawn teardrop shape used for the mascot body.
struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        let top = CGPoint(x: rect.midX, y: rect.minY)
        let center = CGPoint(x: rect.midX, y: rect.maxY - height * 0.28)
        let radius = width * 0.5
        let startAngle = Angle.degrees(10)
        let endAngle = Angle.degrees(170)
        let arcStart = CGPoint(
            x: center.x + radius * cos(startAngle.radians),
            y: center.y + radius * sin(startAngle.radians)
        )

        path.move(to: top)
        path.addCurve(
            to: arcStart,
            control1: CGPoint(x: rect.midX + width * 0.05, y: rect.minY + height * 0.35),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - height * 0.45)
        )
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.addCurve(
            to: top,
            control1: CGPoint(x: rect.minX, y: rect.maxY - height * 0.45),
            control2: CGPoint(x: rect.midX - width * 0.05, y: rect.minY + height * 0.35)
        )
        path.closeSubpath()
        return path
    }
}

enum MascotMood {
    case parched, thirsty, content, happy, overjoyed

    static func forProgress(_ fraction: Double) -> MascotMood {
        switch fraction {
        case ..<0.15: return .parched
        case ..<0.4: return .thirsty
        case ..<0.75: return .content
        case ..<1.0: return .happy
        default: return .overjoyed
        }
    }

    var color: Color {
        switch self {
        case .parched: return Color(red: 0.75, green: 0.78, blue: 0.8)
        case .thirsty: return Color(red: 0.6, green: 0.78, blue: 0.92)
        case .content: return Color(red: 0.35, green: 0.68, blue: 0.92)
        case .happy: return Color(red: 0.18, green: 0.56, blue: 0.93)
        case .overjoyed: return Color(red: 0.1, green: 0.45, blue: 0.95)
        }
    }

    var eyeCurve: Bool { self == .overjoyed || self == .happy }

    var mouthOffset: CGFloat {
        switch self {
        case .parched: return -6
        case .thirsty: return -2
        case .content: return 2
        case .happy: return 6
        case .overjoyed: return 9
        }
    }

    var label: String {
        switch self {
        case .parched: return "Parched"
        case .thirsty: return "Thirsty"
        case .content: return "Doing okay"
        case .happy: return "Feeling great"
        case .overjoyed: return "Fully hydrated!"
        }
    }
}

struct MascotView: View {
    let progress: Double // 0...1+
    var size: CGFloat = 180

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isBreathing = false
    @State private var isBlinking = false
    @State private var bounceScale: CGFloat = 1.0

    private var mood: MascotMood { MascotMood.forProgress(progress) }

    var body: some View {
        ZStack {
            DropletShape()
                .fill(
                    LinearGradient(
                        colors: [mood.color, mood.color.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    DropletShape()
                        .stroke(mood.color.opacity(0.9), lineWidth: 2)
                )
                .frame(width: size, height: size * 1.15)
                .shadow(color: mood.color.opacity(0.35), radius: 12, y: 8)

            // Highlight
            Ellipse()
                .fill(Color.white.opacity(0.35))
                .frame(width: size * 0.18, height: size * 0.28)
                .offset(x: -size * 0.16, y: -size * 0.18)

            // Face
            VStack(spacing: size * 0.05) {
                HStack(spacing: size * 0.16) {
                    eye
                    eye
                }
                mouth
            }
            .offset(y: size * 0.12)
        }
        .scaleEffect(bounceScale)
        .scaleEffect(isBreathing ? 1.03 : 1.0)
        .offset(y: isBreathing ? -6 : 4)
        .rotationEffect(.degrees(isBreathing ? -1.5 : 1.5))
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: mood.color)
        .animation(.interpolatingSpring(stiffness: 260, damping: 9), value: bounceScale)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
            value: isBreathing
        )
        .accessibilityLabel(mood.label)
        .task {
            guard !reduceMotion else { return }
            isBreathing = true
            await runBlinkLoop()
        }
        .onChange(of: progress) { _, _ in
            bounceScale = 1.16
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                bounceScale = 1.0
            }
        }
    }

    private func runBlinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 2.5...5)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { isBlinking = true }
            try? await Task.sleep(for: .seconds(0.12))
            withAnimation(.easeInOut(duration: 0.12)) { isBlinking = false }
        }
    }

    private var eye: some View {
        Circle()
            .fill(Color.white)
            .frame(width: size * 0.09, height: size * 0.09)
            .overlay(
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: size * 0.045, height: size * 0.045)
            )
            .scaleEffect(y: isBlinking ? 0.1 : 1, anchor: .center)
    }

    private var mouth: some View {
        let width = size * 0.32
        let curveAmount = mood.mouthOffset
        return Path { path in
            path.move(to: CGPoint(x: -width / 2, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: width / 2, y: 0),
                control: CGPoint(x: 0, y: curveAmount)
            )
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.02, lineCap: .round))
        .frame(width: width, height: size * 0.1)
    }
}

#Preview {
    VStack(spacing: 30) {
        MascotView(progress: 0.05)
        MascotView(progress: 0.9)
    }
}
