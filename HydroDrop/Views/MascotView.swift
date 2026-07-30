import SwiftUI

// MARK: - Shapes

/// The mascot's body: a teardrop built from the tangent lines that run between a
/// blunted tip and the circle forming its belly.
///
/// Deriving the flanks from real tangents keeps the silhouette perfectly
/// symmetrical and free of the kink that eyeballed control points leave behind.
/// The belly circle is inscribed in `rect`, so the shape always fills the width and
/// touches the bottom edge exactly.
struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.maxY - radius)
        let apex = CGPoint(x: rect.midX, y: rect.minY)
        let reach = center.y - apex.y

        // A frame wider than it is tall can't form a teardrop; fall back to the
        // belly alone rather than drawing a broken path.
        guard reach > radius else {
            path.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return path
        }

        // Half-angle, measured at the belly centre, between straight up and the
        // point where a line from the apex grazes the circle.
        let theta = Angle.radians(acos(radius / reach))
        let tangentRight = CGPoint(
            x: center.x + radius * sin(theta.radians),
            y: center.y - radius * cos(theta.radians)
        )
        let tangentLeft = CGPoint(x: rect.midX - (tangentRight.x - rect.midX), y: tangentRight.y)

        // A blunt tip reads friendlier than a needle point at mascot sizes.
        let tipInset = rect.width * 0.055
        let tipRight = CGPoint(x: apex.x + tipInset * 0.5, y: apex.y + tipInset * 0.75)
        let tipLeft = CGPoint(x: apex.x - tipInset * 0.5, y: apex.y + tipInset * 0.75)

        // Bow the flanks out from the straight tangent so the body looks full of
        // water rather than like a cone.
        let bow = rect.width * 0.04

        path.move(to: tipRight)
        path.addCurve(
            to: tangentRight,
            control1: bowed(from: tipRight, to: tangentRight, at: 0.34, outward: bow, axisX: rect.midX),
            control2: bowed(from: tipRight, to: tangentRight, at: 0.74, outward: bow * 0.7, axisX: rect.midX)
        )
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(theta.degrees - 90),
            endAngle: .degrees(270 - theta.degrees),
            clockwise: false
        )
        path.addCurve(
            to: tipLeft,
            control1: bowed(from: tangentLeft, to: tipLeft, at: 0.26, outward: bow * 0.7, axisX: rect.midX),
            control2: bowed(from: tangentLeft, to: tipLeft, at: 0.66, outward: bow, axisX: rect.midX)
        )
        path.addQuadCurve(to: tipRight, control: apex)
        path.closeSubpath()
        return path
    }

    /// A point `t` of the way from `a` to `b`, pushed `outward` along the segment's
    /// normal, away from the vertical line at `axisX`.
    private func bowed(
        from a: CGPoint,
        to b: CGPoint,
        at t: CGFloat,
        outward: CGFloat,
        axisX: CGFloat
    ) -> CGPoint {
        let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return point }
        var nx = dy / length
        var ny = -dx / length
        if (point.x - axisX) * nx < 0 {
            nx = -nx
            ny = -ny
        }
        return CGPoint(x: point.x + nx * outward, y: point.y + ny * outward)
    }
}

/// A closed, upward-curving eye — the `^ ^` of a delighted cartoon face.
private struct HappyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        )
        return path
    }
}

/// A single arc, curving down for a frown and up for a smile.
private struct SmileShape: Shape {
    /// Positive smiles, negative frowns, as a fraction of the rect's height.
    var curve: CGFloat

    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY + rect.height * curve * 2)
        )
        return path
    }
}

/// A dry, wavering line — the mouth of something that badly needs a drink.
private struct WobbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / 4
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + step * 2, y: rect.midY),
            control: CGPoint(x: rect.minX + step, y: rect.midY - rect.height * 0.7)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.minX + step * 3, y: rect.midY + rect.height * 0.7)
        )
        return path
    }
}

/// An open, beaming mouth: a lens shape with a shallow top lip and a deep jaw.
///
/// Both control points are pushed well past the edges they curve toward, because a
/// quadratic only reaches halfway to its control — aiming them at the rect's own
/// edges would leave the jaw too shallow to hold a tongue.
private struct GrinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.34)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height)
        )
        path.closeSubpath()
        return path
    }
}

/// A four-pointed sparkle with pinched arms.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        let waist: CGFloat = 0.16

        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: cy),
            control: CGPoint(x: cx + rx * waist, y: cy - ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY),
            control: CGPoint(x: cx + rx * waist, y: cy + ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: cy),
            control: CGPoint(x: cx - rx * waist, y: cy + ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control: CGPoint(x: cx - rx * waist, y: cy - ry * waist)
        )
        path.closeSubpath()
        return path
    }
}

/// A pointed leaf, drawn growing upward from the bottom edge.
private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.18)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.midY - rect.height * 0.18)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Mood

enum MascotMood {
    case parched, thirsty, content, happy, overjoyed

    enum EyeStyle {
        /// Open, with a heavy lid drawn across the top.
        case droopy
        /// Open and round.
        case open
        /// Closed and curved upward.
        case arc
    }

    enum MouthStyle {
        case wobble
        /// Arc; positive smiles, negative frowns.
        case curve(CGFloat)
        /// Open and beaming.
        case grin
    }

    static func forProgress(_ fraction: Double) -> MascotMood {
        switch fraction {
        case ..<0.15: return .parched
        case ..<0.4: return .thirsty
        case ..<0.75: return .content
        case ..<1.0: return .happy
        default: return .overjoyed
        }
    }

    /// Index into a `MascotSkin` ramp, ordered parched → overjoyed.
    private var rampIndex: Int {
        switch self {
        case .parched: return 0
        case .thirsty: return 1
        case .content: return 2
        case .happy: return 3
        case .overjoyed: return 4
        }
    }

    func tone(skin: MascotSkin) -> MascotTone {
        skin.tones[rampIndex]
    }

    func color(skin: MascotSkin) -> Color {
        tone(skin: skin).color
    }

    var eyeStyle: EyeStyle {
        switch self {
        case .parched: return .droopy
        case .thirsty, .content, .happy: return .open
        case .overjoyed: return .arc
        }
    }

    /// Eyes widen as hydration improves — the cheapest, clearest mood signal there is.
    var eyeScale: CGFloat {
        switch self {
        case .parched: return 0.86
        case .thirsty: return 0.94
        case .content: return 1.0
        case .happy: return 1.06
        case .overjoyed: return 1.10
        }
    }

    var mouthStyle: MouthStyle {
        switch self {
        case .parched: return .wobble
        case .thirsty: return .curve(-0.30)
        case .content: return .curve(0.34)
        case .happy: return .curve(0.62)
        case .overjoyed: return .grin
        }
    }

    var mouthWidth: CGFloat {
        switch self {
        case .parched: return 0.20
        case .thirsty: return 0.22
        case .content: return 0.26
        case .happy: return 0.31
        case .overjoyed: return 0.30
        }
    }

    /// Degrees the inner end of each brow drops by. Zero hides the brows entirely.
    var browTilt: Double {
        switch self {
        case .parched: return 24
        case .thirsty: return 13
        case .content, .happy, .overjoyed: return 0
        }
    }

    var showsBlush: Bool { self == .happy || self == .overjoyed }
    var showsSweat: Bool { self == .parched }
    var showsSparkles: Bool { self == .overjoyed }

    /// A small permanent lean, so a struggling drop slumps and a thriving one stands up.
    var restTilt: Double {
        switch self {
        case .parched: return 5
        case .thirsty: return 2.5
        case .content, .happy, .overjoyed: return 0
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

// MARK: - Mascot

struct MascotView: View {
    let progress: Double // 0...1+
    var size: CGFloat = 180
    var skin: MascotSkin = .classic
    /// Settings and the paywall show several mascots side by side; holding those
    /// still keeps the lists calm and avoids a dozen repeating animations.
    var isAnimated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isBreathing = false
    @State private var isBlinking = false
    @State private var pop: CGFloat = 0

    private var mood: MascotMood { MascotMood.forProgress(progress) }
    private var tone: MascotTone { mood.tone(skin: skin) }
    private var animates: Bool { isAnimated && !reduceMotion }

    /// Eyes, brows and mouth all share this dark tone. Deriving it from the body
    /// keeps the face readable on the palest "parched" grey and the deepest indigo
    /// alike, which a flat black or white never manages across every skin.
    private var ink: Color { tone.shaded(0.74) }

    /// Body height as a multiple of `size`. The belly circle is `size` wide, so this
    /// is what sets how tall and pointed the drop looks.
    private static let bodyAspect: CGFloat = 1.3

    var body: some View {
        ZStack {
            charmBackdrop
            dropletBody
            charmForeground
            sweatDrop
            sparkles
        }
        .frame(width: size * 1.32, height: size * 1.5)
        .rotationEffect(.degrees(mood.restTilt))
        .scaleEffect(x: 1 - pop * 0.09, y: 1 + pop * 0.13, anchor: .bottom)
        .scaleEffect(isBreathing ? 1.02 : 0.995)
        .offset(y: isBreathing ? -size * 0.022 : size * 0.012)
        .rotationEffect(.degrees(isBreathing ? -1.4 : 1.4))
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: mood)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pop)
        .animation(
            animates ? .easeInOut(duration: 2.6).repeatForever(autoreverses: true) : nil,
            value: isBreathing
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mood.label)
        .task {
            guard animates else { return }
            isBreathing = true
            await runBlinkLoop()
        }
        .onChange(of: progress) { _, _ in
            guard animates else { return }
            // Squash on the way in, then spring back — a gulp, not a jump.
            pop = 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.16))
                pop = 0
            }
        }
    }

    // MARK: Body

    private var dropletBody: some View {
        ZStack {
            DropletShape()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: tone.lit(0.36), location: 0),
                            .init(color: tone.lit(0.06), location: 0.42),
                            .init(color: tone.shaded(0.19), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // A pool of deeper colour in the belly, so the drop reads as a volume of
            // water rather than a flat sticker.
            DropletShape()
                .fill(
                    RadialGradient(
                        colors: [.clear, tone.shaded(0.30).opacity(0.42)],
                        center: UnitPoint(x: 0.5, y: 0.72),
                        startRadius: size * 0.10,
                        endRadius: size * 0.62
                    )
                )
                .blendMode(.multiply)

            charmFill

            // Rim: bright where light lands, deep along the shaded underside.
            DropletShape()
                .stroke(
                    LinearGradient(
                        colors: [tone.lit(0.55).opacity(0.85), tone.shaded(0.22).opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(1, size * 0.014)
                )

            highlights
            face
        }
        .frame(width: size, height: size * Self.bodyAspect)
        .compositingGroup()
        .shadow(color: tone.shaded(0.35).opacity(0.32), radius: size * 0.08, y: size * 0.05)
    }

    private var highlights: some View {
        ZStack {
            // Kept up on the shoulder. Any lower and it lands on the face, where a
            // sheen reads as a scar rather than as light.
            Ellipse()
                .fill(Color.white.opacity(0.40))
                .frame(width: size * 0.17, height: size * 0.26)
                .rotationEffect(.degrees(-22))
                .offset(x: -size * 0.20, y: -size * 0.20)
                .blur(radius: size * 0.018)

            Ellipse()
                .fill(Color.white.opacity(0.24))
                .frame(width: size * 0.07, height: size * 0.12)
                .rotationEffect(.degrees(-22))
                .offset(x: -size * 0.25, y: size * 0.24)
                .blur(radius: size * 0.010)

            // Caustic glint along the shaded flank keeps the right side from going flat.
            Ellipse()
                .fill(Color.white.opacity(0.16))
                .frame(width: size * 0.05, height: size * 0.22)
                .rotationEffect(.degrees(16))
                .offset(x: size * 0.30, y: size * 0.14)
                .blur(radius: size * 0.02)
        }
        // The ZStack would otherwise shrink to its largest ellipse, and the mask
        // would clip every highlight down to a thumbnail-sized droplet.
        .frame(width: size, height: size * Self.bodyAspect)
        .mask { DropletShape() }
    }

    // MARK: Face

    private var face: some View {
        ZStack {
            if mood.showsBlush {
                blush(mirrored: false)
                blush(mirrored: true)
            }

            eye(mirrored: false)
            eye(mirrored: true)

            if mood.browTilt > 0 {
                brow(mirrored: false)
                brow(mirrored: true)
            }

            mouth
        }
    }

    private var eyeCenterY: CGFloat { size * 0.085 }
    private var eyeCenterX: CGFloat { size * 0.155 }

    @ViewBuilder
    private func eye(mirrored: Bool) -> some View {
        let width = size * 0.195 * mood.eyeScale
        let height = size * 0.225 * mood.eyeScale
        let x = mirrored ? eyeCenterX : -eyeCenterX

        Group {
            switch mood.eyeStyle {
            case .arc:
                HappyEyeShape()
                    .stroke(ink, style: StrokeStyle(lineWidth: size * 0.028, lineCap: .round))
                    .frame(width: width, height: height * 0.42)
            case .open, .droopy:
                Ellipse()
                    .fill(Color.white)
                    .frame(width: width, height: height)
                    .overlay(pupil(width: width, height: height))
                    .overlay(eyelid(width: width, height: height))
                    .clipShape(Ellipse())
                    .scaleEffect(y: isBlinking ? 0.08 : 1, anchor: .center)
            }
        }
        .offset(x: x, y: eyeCenterY)
    }

    private func pupil(width: CGFloat, height: CGFloat) -> some View {
        let diameter: CGFloat = width * 0.58
        let mainGlint: CGFloat = diameter * 0.34
        let mainGlintX: CGFloat = -diameter * 0.18
        let mainGlintY: CGFloat = -diameter * 0.22
        let minorGlint: CGFloat = diameter * 0.16
        let minorGlintOffset: CGFloat = diameter * 0.21

        return Circle()
            .fill(ink)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: mainGlint, height: mainGlint)
                    .offset(x: mainGlintX, y: mainGlintY)
            )
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: minorGlint, height: minorGlint)
                    .offset(x: minorGlintOffset, y: minorGlintOffset)
            )
            // A pupil sitting slightly low in the eye reads as friendly rather than startled.
            .offset(y: height * 0.05)
    }

    @ViewBuilder
    private func eyelid(width: CGFloat, height: CGFloat) -> some View {
        if mood.eyeStyle == .droopy {
            Ellipse()
                .fill(tone.shaded(0.12))
                .frame(width: width * 1.2, height: height)
                .offset(y: -height * 0.52)
        }
    }

    private func brow(mirrored: Bool) -> some View {
        // Inner ends up, outer ends down. The opposite slant is the universal
        // cartoon shorthand for angry, which is not what a thirsty drop should look like.
        let tilt = mirrored ? mood.browTilt : -mood.browTilt

        return Capsule()
            .fill(ink)
            .frame(width: size * 0.10, height: size * 0.020)
            .rotationEffect(.degrees(tilt))
            .offset(
                x: mirrored ? eyeCenterX + size * 0.006 : -(eyeCenterX + size * 0.006),
                y: eyeCenterY - size * 0.125
            )
    }

    private func blush(mirrored: Bool) -> some View {
        // Pale rather than saturated: a strong pink disappears into the Sunrise body
        // and turns muddy on Forest, where a light warm tint still reads as a cheek.
        Ellipse()
            .fill(Color(red: 1.0, green: 0.76, blue: 0.78).opacity(0.6))
            .frame(width: size * 0.14, height: size * 0.075)
            .blur(radius: size * 0.016)
            .offset(x: mirrored ? size * 0.27 : -size * 0.27, y: eyeCenterY + size * 0.11)
    }

    private var mouthCenterY: CGFloat { eyeCenterY + size * 0.17 }

    @ViewBuilder
    private var mouth: some View {
        let width = size * mood.mouthWidth

        switch mood.mouthStyle {
        case .wobble:
            WobbleShape()
                .stroke(ink, style: StrokeStyle(lineWidth: size * 0.022, lineCap: .round))
                .frame(width: width, height: size * 0.05)
                .offset(y: mouthCenterY)
        case .curve(let amount):
            SmileShape(curve: amount)
                .stroke(ink, style: StrokeStyle(lineWidth: size * 0.024, lineCap: .round))
                .frame(width: width, height: size * 0.09)
                .offset(y: mouthCenterY)
        case .grin:
            let height = size * 0.13
            GrinShape()
                .fill(ink)
                .frame(width: width, height: height)
                .overlay {
                    // Tongue. Sunk low and then clipped, so only the part sitting in
                    // the jaw survives.
                    Ellipse()
                        .fill(Color(red: 1.0, green: 0.50, blue: 0.56))
                        .frame(width: width * 0.56, height: height * 0.7)
                        .offset(y: height * 0.45)
                }
                .clipShape(GrinShape())
                .offset(y: mouthCenterY + size * 0.012)
        }
    }

    // MARK: Mood accents

    @ViewBuilder
    private var sweatDrop: some View {
        if mood.showsSweat {
            DropletShape()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    DropletShape()
                        .stroke(tone.shaded(0.35).opacity(0.4), lineWidth: max(0.5, size * 0.006))
                )
                .frame(width: size * 0.11, height: size * 0.11 * Self.bodyAspect)
                .rotationEffect(.degrees(28))
                .offset(x: size * 0.34, y: -size * 0.26)
        }
    }

    /// Sunrise and Midnight already fill the air around the drop with their own
    /// charm; adding celebration sparkles on top just makes a mess.
    private var charmOwnsTheAir: Bool {
        switch skin.charm {
        case .sunGlow, .starlight: return true
        case .none, .sprout, .fizz: return false
        }
    }

    @ViewBuilder
    private var sparkles: some View {
        if mood.showsSparkles && !charmOwnsTheAir {
            Twinkle(diameter: size * 0.14, offset: CGPoint(x: -size * 0.42, y: -size * 0.26),
                    tint: skin.accent, delay: 0, animated: animates)
            Twinkle(diameter: size * 0.10, offset: CGPoint(x: size * 0.44, y: -size * 0.12),
                    tint: skin.accent, delay: 0.45, animated: animates)
            Twinkle(diameter: size * 0.08, offset: CGPoint(x: size * 0.24, y: -size * 0.48),
                    tint: skin.accent, delay: 0.85, animated: animates)
        }
    }

    // MARK: Charms

    /// Charm layers that sit behind the body.
    @ViewBuilder
    private var charmBackdrop: some View {
        switch skin.charm {
        case .sunGlow:
            SunGlow(size: size, tint: skin.accent, animated: animates)
        case .starlight:
            Starlight(size: size, tint: skin.accent, animated: animates)
        case .none, .sprout, .fizz:
            EmptyView()
        }
    }

    /// Charm layers painted inside the body, clipped to its silhouette.
    @ViewBuilder
    private var charmFill: some View {
        if case .fizz = skin.charm {
            ZStack {
                FizzBubble(size: size, column: -0.92, restY: 0.22, scale: 1.0, duration: 3.4,
                           delay: 0.0, tint: skin.accent, animated: animates)
                FizzBubble(size: size, column: -0.60, restY: 0.40, scale: 0.7, duration: 4.2,
                           delay: 0.9, tint: skin.accent, animated: animates)
                FizzBubble(size: size, column: 0.66, restY: 0.36, scale: 1.15, duration: 3.0,
                           delay: 1.7, tint: skin.accent, animated: animates)
                FizzBubble(size: size, column: 0.95, restY: 0.14, scale: 0.8, duration: 3.8,
                           delay: 2.4, tint: skin.accent, animated: animates)
            }
            // Same trap as `highlights`: without an explicit frame the mask collapses
            // to the size of a single bubble.
            .frame(width: size, height: size * Self.bodyAspect)
            .mask { DropletShape() }
        }
    }

    /// Charm layers that sit in front of, or grow out of, the body.
    @ViewBuilder
    private var charmForeground: some View {
        if case .sprout = skin.charm {
            Sprout(size: size, tint: skin.accent, swaying: isBreathing)
                .offset(y: -size * 0.67)
        }
    }

    // MARK: Animation

    private func runBlinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 2.5...5)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { isBlinking = true }
            try? await Task.sleep(for: .seconds(0.11))
            withAnimation(.easeInOut(duration: 0.12)) { isBlinking = false }
        }
    }
}

// MARK: - Charm pieces

/// Sunrise: a warm halo with a fan of slowly turning rays above the drop.
private struct SunGlow: View {
    let size: CGFloat
    let tint: Color
    let animated: Bool

    @State private var turning = false

    private static let rayAngles: [Double] = [-58, -30, 0, 30, 58]

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.0)],
                        center: .center,
                        startRadius: size * 0.26,
                        endRadius: size * 0.70
                    )
                )
                .frame(width: size * 1.4, height: size * 1.4)
                .offset(y: size * 0.06)

            ZStack {
                ForEach(Self.rayAngles, id: \.self) { angle in
                    Capsule()
                        .fill(tint.opacity(0.7))
                        .frame(width: size * 0.022, height: size * 0.09)
                        .offset(y: -size * 0.62)
                        .rotationEffect(.degrees(angle))
                }
            }
            .offset(y: size * 0.05)
            .rotationEffect(.degrees(turning ? 7 : -7))
            .animation(
                animated ? .easeInOut(duration: 5).repeatForever(autoreverses: true) : nil,
                value: turning
            )
            .onAppear { if animated { turning = true } }
        }
    }
}

/// Forest: a two-leaf sprout growing from the tip, swaying with the drop's breath.
private struct Sprout: View {
    let size: CGFloat
    let tint: Color
    let swaying: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(tint)
                .frame(width: size * 0.022, height: size * 0.10)

            leaf(mirrored: false)
            leaf(mirrored: true)
        }
        .frame(width: size * 0.34, height: size * 0.16, alignment: .bottom)
        .rotationEffect(.degrees(swaying ? 5 : -5), anchor: .bottom)
    }

    private func leaf(mirrored: Bool) -> some View {
        LeafShape()
            .fill(
                LinearGradient(
                    colors: [tint, tint.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size * 0.075, height: size * 0.135)
            .rotationEffect(.degrees(mirrored ? 42 : -42), anchor: .bottom)
            .offset(x: mirrored ? size * 0.035 : -size * 0.035, y: -size * 0.055)
    }
}

/// Grape: a bubble drifting up through the body and fading out near the top.
private struct FizzBubble: View {
    let size: CGFloat
    /// Horizontal placement, -1 (left flank) to 1 (right flank).
    let column: CGFloat
    /// Where the bubble parks when it isn't animating, as a fraction of `size`.
    /// Held still it has to look deliberately placed, not stuck at the start of its run.
    let restY: CGFloat
    let scale: CGFloat
    let duration: Double
    let delay: Double
    let tint: Color
    let animated: Bool

    @State private var rising = false

    var body: some View {
        let diameter = size * 0.045 * scale
        Circle()
            .strokeBorder(tint.opacity(0.6), lineWidth: max(0.5, diameter * 0.14))
            .background { Circle().fill(tint.opacity(0.30)) }
            .frame(width: diameter, height: diameter)
            .offset(
                // Wide enough to travel up the flanks. Bubbles drifting across the
                // eyes and mouth read as smudges on the screen, not as fizz.
                x: size * 0.33 * column,
                y: animated ? (rising ? -size * 0.34 : size * 0.52) : size * restY
            )
            .opacity(animated ? (rising ? 0 : 0.95) : 0.9)
            .animation(
                animated
                    ? .linear(duration: duration).repeatForever(autoreverses: false).delay(delay)
                    : nil,
                value: rising
            )
            .onAppear { if animated { rising = true } }
    }
}

/// Midnight: a scatter of stars twinkling in the air around the drop.
private struct Starlight: View {
    let size: CGFloat
    let tint: Color
    let animated: Bool

    private static let stars: [(x: CGFloat, y: CGFloat, scale: CGFloat, delay: Double)] = [
        (-0.46, -0.30, 1.0, 0.0),
        (0.44, -0.40, 0.7, 0.6),
        (0.50, 0.06, 0.85, 1.1),
        (-0.40, 0.30, 0.6, 0.35),
        (0.16, -0.60, 0.75, 0.85),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.stars.indices, id: \.self) { index in
                let star = Self.stars[index]
                Twinkle(
                    diameter: size * 0.13 * star.scale,
                    offset: CGPoint(x: size * star.x, y: size * star.y),
                    tint: tint,
                    delay: star.delay,
                    animated: animated
                )
            }
        }
    }
}

/// A sparkle that pulses in and out.
private struct Twinkle: View {
    let diameter: CGFloat
    let offset: CGPoint
    let tint: Color
    let delay: Double
    let animated: Bool

    @State private var lit = false

    /// Held still, a sparkle should be at full brightness rather than caught at the
    /// dim end of a pulse it will never finish.
    private var isBright: Bool { lit || !animated }

    var body: some View {
        SparkleShape()
            .fill(tint)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isBright ? 1 : 0.45)
            .opacity(isBright ? 1 : 0.3)
            .offset(x: offset.x, y: offset.y)
            .animation(
                animated
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(delay)
                    : nil,
                value: lit
            )
            .onAppear { if animated { lit = true } }
    }
}

// MARK: - Previews

#Preview("Moods") {
    let samples: [Double] = [0.0, 0.3, 0.6, 0.9, 1.1]
    return ScrollView(.horizontal) {
        HStack(spacing: 8) {
            ForEach(samples, id: \.self) { sample in
                VStack {
                    MascotView(progress: sample, size: 110)
                    Text(MascotMood.forProgress(sample).label).font(.caption2)
                }
            }
        }
        .padding()
    }
}

#Preview("Skins") {
    ScrollView(.horizontal) {
        HStack(spacing: 8) {
            ForEach(MascotSkin.allCases) { skin in
                VStack {
                    MascotView(progress: 1.1, size: 110, skin: skin)
                    Text(skin.label).font(.caption2)
                }
            }
        }
        .padding()
    }
}
