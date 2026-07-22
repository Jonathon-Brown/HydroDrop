import SwiftUI

/// A simple hand-drawn teardrop shape used for the mascot body.
struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        let top = CGPoint(x: rect.midX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY - height * 0.05)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY - height * 0.05)

        path.move(to: top)
        path.addCurve(
            to: bottomRight,
            control1: CGPoint(x: rect.midX + width * 0.05, y: rect.minY + height * 0.35),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - height * 0.45)
        )
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY - height * 0.28),
            radius: width * 0.5,
            startAngle: .degrees(10),
            endAngle: .degrees(170),
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
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: mood.color)
        .accessibilityLabel(mood.label)
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
