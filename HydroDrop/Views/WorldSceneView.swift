import SwiftUI

/// The droplet's world, drawn: a pond, a bank, and whatever has grown there so far.
///
/// All of it is `Canvas`, shapes and gradients, in the same hand as `DropletShape`. No
/// images and no sprites. Every stage adds to the scene and nothing ever leaves it:
/// low vitality pales the colours, bends the plants and lowers the water, and that is
/// all it does.
///
/// One `Canvas`, redrawn thirty times a second at most and not at all under Reduce
/// Motion, with nothing in it more expensive than a gradient. Cheap enough to sit behind
/// the mascot on Today without anyone's phone noticing.
struct WorldSceneView: View {
    let state: WorldState
    var decorations: [WorldDecoration] = []
    var timeOfDay: WorldTimeOfDay = .day
    var weather: WorldWeather?
    /// Off for the share card and anywhere else a still picture is wanted.
    var isAnimated = true
    /// How tall the world itself is, when the view is taller than that. The world sits
    /// at the bottom and the rest is more sky, stars and all, for words to sit on.
    var worldHeight: CGFloat?
    /// Plain bank under the world, for something to fade out over without losing the
    /// bottom of the pond.
    var groundBelow: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isAnimated && !reduceMotion {
                // Stops drawing the moment the app is not in front. Nobody is watching
                // the reeds sway from the app switcher.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(at: 0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.spokenDescription)
        .accessibilityAddTraits(.isImage)
    }

    private func canvas(at time: TimeInterval) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let footroom = min(groundBelow, size.height)
            // `size` here is the true, safe-area-ignoring full height (see the comment on
            // `HomeView.worldBackdrop`), so this headroom works out to exactly
            // `safeTop + worldHeaderHeight` — where the header's own bottom edge actually
            // lands on screen, since `ScrollView` pads its content by the top safe area.
            let headroom = worldHeight.map { max(0, size.height - footroom - $0) } ?? 0
            var context = context
            context.translateBy(x: 0, y: headroom)
            var painter = WorldPainter(
                context: context,
                size: CGSize(width: size.width, height: size.height - headroom - footroom),
                headroom: headroom,
                footroom: footroom,
                time: time,
                state: state,
                decorations: decorations,
                timeOfDay: timeOfDay,
                weather: weather
            )
            painter.paint()
        }
    }
}

/// Does the drawing. A value that lives for one frame.
private struct WorldPainter {
    var context: GraphicsContext
    let size: CGSize
    /// Sky above the world's top edge (negative y), which only the sky and what lives in
    /// it reach up into.
    let headroom: CGFloat
    /// Bank below the world's bottom edge (y beyond h), which only the bank reaches down into.
    let footroom: CGFloat
    let time: TimeInterval
    let state: WorldState
    let decorations: [WorldDecoration]
    let timeOfDay: WorldTimeOfDay
    let weather: WorldWeather?

    private var w: CGFloat { size.width }
    private var h: CGFloat { size.height }
    private var vitality: Double { state.vitality }
    private var stage: WorldStage { state.stage }
    /// How far plants hang their heads: 0 upright, 1 fully drooped.
    private var droop: Double { max(0, min(1, (0.55 - vitality) / 0.55)) }
    private var isOvercast: Bool { weather == .cloudy || weather == .rain || weather == .snow }

    /// Fixed sizes (petals, stars, stroke widths) grow with the frame, so a bigger scene
    /// is a closer look rather than the same flowers lost in more space. Capped, so an
    /// iPad-wide scene gets more world rather than cartoonishly fat petals.
    private var unit: CGFloat { min(1.4, max(0.8, sqrt(w * h / (370 * 300)))) }

    /// How far the slow sideways drift has carried the nearest things. The mascot's idle
    /// bob takes 5.2 seconds; this takes 7, so the ground drifts a little slower than the
    /// droplet breathes. Everything further back moves less, which is what reads as depth.
    private var drift: CGFloat { w * 0.009 * sin(time * 2 * .pi / 7) }

    private func has(_ wanted: WorldStage) -> Bool { stage >= wanted }
    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: w * x, y: h * y) }

    /// A steady, repeatable "random" number in 0..<1 for the nth thing of a kind, so
    /// stars and flowers stay where they are from one frame to the next.
    private func scatter(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
        return value - floor(value)
    }

    // MARK: Colour

    /// One authored colour, as it looks in this light, this weather and this health.
    private func tone(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1, living: Bool = true) -> Color {
        var r = red, g = green, b = blue

        // Thirst pales living things towards straw. It never touches the sky.
        if living {
            let fade = (1 - vitality) * 0.6
            r += (0.80 - r) * fade
            g += (0.76 - g) * fade
            b += (0.62 - b) * fade
        }
        // Cloud flattens everything a little.
        if isOvercast {
            let grey = (r + g + b) / 3
            r += (grey - r) * 0.35
            g += (grey - g) * 0.35
            b += (grey - b) * 0.35
        }
        switch timeOfDay {
        case .day:
            break
        case .dawn:
            r = min(1, r * 1.04 + 0.03); g *= 0.97; b *= 0.95
        case .dusk:
            r = min(1, r * 1.02 + 0.02); g *= 0.86; b *= 0.88
        case .night:
            r *= 0.34; g *= 0.42; b *= 0.62
        }
        return Color(red: r, green: g, blue: b, opacity: alpha)
    }

    // MARK: The whole picture

    mutating func paint() {
        // A first layout pass can hand over a zero-sized canvas; there is nothing to draw.
        guard w > 0, h > 0 else { return }
        let still = context
        sky()
        atDepth(0.08, from: still)
        sunOrMoon()
        atDepth(0.15, from: still)
        clouds()
        atDepth(0.25, from: still)
        ridge(base: 0.60, swell: 0.12, phase: 0.4, color: tone(0.55, 0.74, 0.70, living: false))
        atDepth(0.40, from: still)
        ridge(base: 0.64, swell: 0.08, phase: 2.1, color: tone(0.44, 0.68, 0.56))
        if decorations.contains(.bunting) { bunting() }
        if decorations.contains(.balloon) { balloon() }
        atDepth(0.60, from: still)
        if has(.tree) { tree() }
        if decorations.contains(.birdhouse) { birdhouse() }
        bank()
        if decorations.contains(.bridge) { bridge() }
        pond()
        if decorations.contains(.steppingStones) { steppingStones() }
        if has(.koi) { koi() }
        if has(.lilyPads) { lilyPads() }
        if decorations.contains(.paperBoat) { paperBoat() }
        if decorations.contains(.rubberDuck) { rubberDuck() }
        atDepth(1.0, from: still)
        if has(.reeds) { reeds() }
        if has(.flowers) { flowers() }
        if has(.sprout) { sprout() }
        if decorations.contains(.mushrooms) { mushrooms() }
        // In front of the reeds that grow up around its post.
        if decorations.contains(.lantern) { lantern() }
        if has(.fireflies) { firefliesOrDragonflies() }
        // Weather is in front of everything and belongs to no layer.
        context = still
        precipitation()
    }

    /// Draws what follows shifted by this layer's share of the drift: 0 stays put, 1 is
    /// the nearest ground. At rest (Reduce Motion, the share card) the drift is zero.
    private mutating func atDepth(_ depth: Double, from still: GraphicsContext) {
        context = still
        context.translateBy(x: drift * depth, y: 0)
    }

    // MARK: Light

    /// A soft pool of light: bright at the middle, falling away over several steps, with
    /// no edge anywhere. What every light source in the scene sits inside.
    private mutating func glow(at centre: CGPoint, radius: CGFloat, color: Color, strength: Double) {
        let stops = Gradient(stops: [
            .init(color: color.opacity(strength), location: 0),
            .init(color: color.opacity(strength * 0.78), location: 0.25),
            .init(color: color.opacity(strength * 0.42), location: 0.50),
            .init(color: color.opacity(strength * 0.14), location: 0.78),
            .init(color: color.opacity(0), location: 1),
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(stops, center: centre, startRadius: 0, endRadius: radius)
        )
    }

    /// A disc whose rim melts into what is behind it instead of stopping dead.
    private mutating func softDisc(at centre: CGPoint, radius: CGFloat, color: Color) {
        let outer = radius * 1.18
        let stops = Gradient(stops: [
            .init(color: color, location: 0),
            .init(color: color, location: 0.80),
            .init(color: color.opacity(0), location: 1),
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - outer, y: centre.y - outer, width: outer * 2, height: outer * 2)),
            with: .radialGradient(stops, center: centre, startRadius: 0, endRadius: outer)
        )
    }

    // MARK: Sky

    /// Four bands from the top of the sky down to the hills, each time of day its own:
    /// deep overhead, lighter and warmer where the sky meets the land.
    static func skyBands(_ timeOfDay: WorldTimeOfDay) -> [(Double, Double, Double)] {
        switch timeOfDay {
        case .dawn: [(0.38, 0.52, 0.82), (0.66, 0.72, 0.92), (0.98, 0.80, 0.76), (1.00, 0.89, 0.68)]
        case .day: [(0.30, 0.60, 0.94), (0.50, 0.76, 0.97), (0.76, 0.89, 0.99), (0.92, 0.96, 1.00)]
        case .dusk: [(0.20, 0.20, 0.46), (0.46, 0.33, 0.62), (0.93, 0.56, 0.52), (1.00, 0.76, 0.50)]
        case .night: [(0.02, 0.03, 0.12), (0.06, 0.08, 0.25), (0.15, 0.16, 0.38), (0.30, 0.27, 0.48)]
        }
    }

    /// The grey that cloud lays over the whole sky, if there is cloud.
    static func skyVeil(timeOfDay: WorldTimeOfDay, weather: WorldWeather?) -> (color: (Double, Double, Double), opacity: Double)? {
        guard weather == .cloudy || weather == .rain || weather == .snow else { return nil }
        let color = timeOfDay.isDark ? (0.10, 0.11, 0.16) : (0.62, 0.66, 0.72)
        return (color, weather == .cloudy ? 0.45 : 0.6)
    }

    private mutating func sky() {
        let bands = Self.skyBands(timeOfDay)
        let locations = [0.0, 0.40, 0.75, 1.0]
        let gradient = Gradient(stops: zip(bands, locations).map { band, location in
            .init(color: Color(red: band.0, green: band.1, blue: band.2), location: location)
        })
        // Above the world the gradient holds its top colour, so headroom is seamless.
        let rect = CGRect(x: 0, y: -headroom, width: w, height: h + headroom)
        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.64)))
        if let veil = Self.skyVeil(timeOfDay: timeOfDay, weather: weather) {
            let color = Color(red: veil.color.0, green: veil.color.1, blue: veil.color.2)
            context.fill(Path(rect), with: .color(color.opacity(veil.opacity)))
        }
    }

    private mutating func sunOrMoon() {
        guard !isOvercast else { return }
        if timeOfDay.isDark {
            // The same density of stars however much sky there is, up to a point.
            let starry = h * 0.5 + headroom
            for index in 0..<Int(26 * min(3, starry / (h * 0.5))) {
                let twinkle = 0.45 + 0.55 * abs(sin(time * (0.6 + scatter(index, 3)) + Double(index)))
                let across = (1.6 + scatter(index, 4) * 1.4) * unit
                let star = CGRect(x: w * scatter(index, 1), y: starry * scatter(index, 2) - headroom, width: across, height: across)
                context.fill(Path(ellipseIn: star), with: .color(.white.opacity(0.85 * twinkle)))
            }
            let centre = point(0.80, 0.17)
            let radius = w * 0.055
            let moonlight = Color(red: 0.86, green: 0.90, blue: 1.0)
            glow(at: centre, radius: radius * 6, color: moonlight, strength: 0.30)
            glow(at: centre, radius: radius * 2.4, color: moonlight, strength: 0.45)
            softDisc(at: centre, radius: radius, color: Color(red: 0.97, green: 0.96, blue: 0.88))
            return
        }
        let height: Double = timeOfDay == .day ? 0.16 : 0.40
        let centre = point(timeOfDay == .dawn ? 0.22 : 0.80, height)
        let radius = w * 0.06
        let warm = timeOfDay == .day ? Color(red: 1.0, green: 0.93, blue: 0.62) : Color(red: 1.0, green: 0.78, blue: 0.52)
        glow(at: centre, radius: radius * 6, color: warm, strength: 0.35)
        glow(at: centre, radius: radius * 2.2, color: warm, strength: 0.55)
        softDisc(at: centre, radius: radius, color: warm)
    }

    private mutating func clouds() {
        let count = isOvercast ? 4 : (timeOfDay.isDark ? 0 : 2)
        guard count > 0 else { return }
        let shade: Color = isOvercast
            ? (timeOfDay.isDark ? Color(red: 0.26, green: 0.28, blue: 0.36) : Color(red: 0.80, green: 0.83, blue: 0.87))
            : .white
        for index in 0..<count {
            let drift = (time * (0.004 + scatter(index, 9) * 0.004) + scatter(index, 5)).truncatingRemainder(dividingBy: 1.3) - 0.15
            let centre = point(drift, 0.10 + 0.22 * scatter(index, 6))
            let scale = w * (0.07 + 0.05 * scatter(index, 7))
            var cloud = Path()
            for (dx, dy, r) in [(-1.0, 0.15, 0.75), (-0.2, -0.2, 1.0), (0.75, 0.0, 0.85), (0.1, 0.3, 0.9)] {
                cloud.addEllipse(in: CGRect(
                    x: centre.x + scale * dx - scale * r,
                    y: centre.y + scale * dy * 0.7 - scale * r * 0.6,
                    width: scale * r * 2,
                    height: scale * r * 1.2
                ))
            }
            context.fill(cloud, with: .color(shade.opacity(isOvercast ? 0.9 : 0.8)))
        }
    }

    // MARK: Land and water

    /// One line of hills. Runs a little past both edges, so the drift never shows a gap.
    private mutating func ridge(base: Double, swell: Double, phase: Double, color: Color) {
        var path = Path()
        path.move(to: point(-0.05, 1))
        for step in 0...26 {
            let x = -0.05 + 1.1 * Double(step) / 26
            let y = base - swell * (sin(x * 3.1 + phase) * 0.6 + sin(x * 7.3 + phase * 2) * 0.25 + 0.5)
            path.addLine(to: point(x, y))
        }
        path.addLine(to: point(1.05, 1))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private mutating func bank() {
        var path = Path()
        path.move(to: CGPoint(x: -w * 0.05, y: h + footroom))
        path.addLine(to: point(-0.05, 0.665))
        path.addCurve(to: point(1.05, 0.64), control1: point(0.3, 0.60), control2: point(0.7, 0.68))
        path.addLine(to: CGPoint(x: w * 1.05, y: h + footroom))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [tone(0.42, 0.72, 0.38), tone(0.30, 0.58, 0.30)]),
            startPoint: point(0, 0.62),
            endPoint: point(0, 1)
        ))
    }

    private var pondCentre: CGPoint { point(0.5, 0.83) }
    private var pondRadii: CGSize { CGSize(width: w * 0.40, height: h * 0.115) }
    /// The water drops as the world dries, and leaves its muddy rim showing.
    private var waterLevel: Double { 0.70 + 0.30 * vitality }

    private func pondEllipse(scale: Double) -> CGRect {
        CGRect(
            x: pondCentre.x - pondRadii.width * scale,
            y: pondCentre.y - pondRadii.height * scale,
            width: pondRadii.width * 2 * scale,
            height: pondRadii.height * 2 * scale
        )
    }

    /// A point on the water, by angle and by how far out from the middle.
    private func onWater(angle: Double, reach: Double) -> CGPoint {
        CGPoint(
            x: pondCentre.x + cos(angle) * pondRadii.width * waterLevel * reach,
            y: pondCentre.y + sin(angle) * pondRadii.height * waterLevel * reach
        )
    }

    private mutating func pond() {
        context.fill(Path(ellipseIn: pondEllipse(scale: 1.04)), with: .color(tone(0.47, 0.37, 0.26, living: false)))
        let water = pondEllipse(scale: waterLevel)
        context.fill(Path(ellipseIn: water), with: .linearGradient(
            Gradient(colors: [tone(0.40, 0.74, 0.93, living: false), tone(0.16, 0.50, 0.84, living: false)]),
            startPoint: CGPoint(x: water.midX, y: water.minY),
            endPoint: CGPoint(x: water.midX, y: water.maxY)
        ))
        // A few slow glints, so the water is never quite still.
        for index in 0..<4 {
            let sweep = (time * 0.05 + scatter(index, 11)).truncatingRemainder(dividingBy: 1)
            let centre = onWater(angle: .pi * (0.15 + 0.7 * scatter(index, 12)), reach: 0.15 + 0.6 * sweep)
            let length = w * (0.05 + 0.04 * scatter(index, 13))
            var glint = Path()
            glint.move(to: CGPoint(x: centre.x - length / 2, y: centre.y))
            glint.addQuadCurve(to: CGPoint(x: centre.x + length / 2, y: centre.y), control: CGPoint(x: centre.x, y: centre.y - 2))
            context.stroke(glint, with: .color(.white.opacity(0.35 * sin(sweep * .pi))), style: StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round))
        }
    }

    // MARK: What has grown

    /// A stem from the ground up, leaning with the breeze and hanging its head when dry.
    /// Returns where the top ended up, for whatever sits on it.
    private mutating func stem(from base: CGPoint, height: CGFloat, sway: Double, color: Color, width: CGFloat) -> CGPoint {
        let lean = sin(time * 0.9 + sway) * Double(height) * 0.04 + Double(height) * 0.55 * droop * (sway.truncatingRemainder(dividingBy: 2) < 1 ? 1 : -1)
        let top = CGPoint(x: base.x + lean, y: base.y - height * (1 - 0.30 * droop))
        var path = Path()
        path.move(to: base)
        path.addQuadCurve(to: top, control: CGPoint(x: base.x, y: base.y - height * 0.75))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        return top
    }

    private func leaf(at origin: CGPoint, length: CGFloat, angle: Double) -> Path {
        let tip = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
        let normal = CGPoint(x: -sin(angle) * length * 0.32, y: cos(angle) * length * 0.32)
        let middle = CGPoint(x: (origin.x + tip.x) / 2, y: (origin.y + tip.y) / 2)
        var path = Path()
        path.move(to: origin)
        path.addQuadCurve(to: tip, control: CGPoint(x: middle.x + normal.x, y: middle.y + normal.y))
        path.addQuadCurve(to: origin, control: CGPoint(x: middle.x - normal.x, y: middle.y - normal.y))
        return path
    }

    private mutating func sprout() {
        let base = point(0.22, 0.72)
        let height = h * 0.085
        let top = stem(from: base, height: height, sway: 0.3, color: tone(0.30, 0.62, 0.26), width: 2.2 * unit)
        let hang = droop * 0.9
        context.fill(leaf(at: top, length: height * 0.62, angle: -.pi * 0.80 + hang), with: .color(tone(0.45, 0.80, 0.32)))
        context.fill(leaf(at: top, length: height * 0.62, angle: -.pi * 0.20 - hang), with: .color(tone(0.40, 0.76, 0.30)))
    }

    private mutating func reeds() {
        for index in 0..<6 {
            let base = onWater(angle: -0.25 + 0.16 * Double(index), reach: 1.02 / waterLevel * 0.98)
            let height = h * (0.16 + 0.07 * scatter(index, 21))
            let top = stem(from: base, height: height, sway: Double(index) * 1.7, color: tone(0.36, 0.58, 0.26), width: 1.8 * unit)
            guard index % 2 == 0 else { continue }
            let head = CGRect(x: top.x - 2.2 * unit, y: top.y - h * 0.035, width: 4.4 * unit, height: h * 0.05)
            context.fill(Path(roundedRect: head, cornerRadius: 2.2 * unit), with: .color(tone(0.45, 0.30, 0.18, living: false)))
        }
    }

    private mutating func lilyPads() {
        let spots: [(Double, Double, Double)] = [(2.55, 0.62, 1.0), (0.75, 0.55, 0.8), (1.75, 0.30, 0.7)]
        for (index, spot) in spots.enumerated() {
            let bob = sin(time * 0.7 + Double(index) * 2) * 1.2
            let centre = onWater(angle: spot.0, reach: spot.1)
            let rx = w * 0.055 * spot.2, ry = h * 0.022 * spot.2
            var pad = Path()
            pad.move(to: CGPoint(x: centre.x, y: centre.y + bob))
            pad.addArc(center: CGPoint(x: centre.x, y: centre.y + bob), radius: 1, startAngle: .degrees(20), endAngle: .degrees(340), clockwise: false)
            pad.closeSubpath()
            let shaped = pad.applying(CGAffineTransform(translationX: -centre.x, y: -(centre.y + bob)))
                .applying(CGAffineTransform(scaleX: rx, y: ry))
                .applying(CGAffineTransform(translationX: centre.x, y: centre.y + bob))
            context.fill(shaped, with: .color(tone(0.30, 0.64, 0.34)))
            // In flower while the world is well. The pad stays either way.
            if index == 0, vitality >= 0.55 {
                for petal in 0..<6 {
                    let angle = Double(petal) / 6 * 2 * .pi
                    let spotRect = CGRect(x: centre.x + cos(angle) * 4 - 3, y: centre.y + bob - 5 + sin(angle) * 2.2 - 2.2, width: 6, height: 4.4)
                    context.fill(Path(ellipseIn: spotRect), with: .color(tone(0.98, 0.72, 0.84, living: false)))
                }
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 2, y: centre.y + bob - 7, width: 4, height: 4)), with: .color(tone(0.99, 0.86, 0.40, living: false)))
            }
        }
    }

    private mutating func flowers() {
        let petals: [(Double, Double, Double)] = [(0.96, 0.45, 0.55), (0.99, 0.80, 0.30), (0.72, 0.55, 0.95), (0.98, 0.98, 0.98), (0.98, 0.58, 0.36)]
        // All on the bank: every one of these is outside the pond's rim.
        let beds: [(Double, Double)] = [(0.04, 0.80), (0.08, 0.91), (0.20, 0.95), (0.80, 0.96), (0.93, 0.91), (0.97, 0.80), (0.66, 0.985)]
        for (index, bed) in beds.enumerated() {
            let height = h * (0.060 + 0.030 * scatter(index, 31))
            let top = stem(from: point(bed.0, bed.1), height: height, sway: Double(index) * 2.3, color: tone(0.32, 0.60, 0.28), width: 1.6 * unit)
            let colour = petals[index % petals.count]
            let radius = (3.0 + 1.5 * scatter(index, 32)) * unit
            for petal in 0..<5 {
                let angle = Double(petal) / 5 * 2 * .pi + Double(index)
                let rect = CGRect(x: top.x + cos(angle) * radius - radius * 0.7, y: top.y + sin(angle) * radius - radius * 0.7, width: radius * 1.4, height: radius * 1.4)
                context.fill(Path(ellipseIn: rect), with: .color(tone(colour.0, colour.1, colour.2)))
            }
            context.fill(Path(ellipseIn: CGRect(x: top.x - radius * 0.5, y: top.y - radius * 0.5, width: radius, height: radius)), with: .color(tone(0.98, 0.84, 0.30)))
        }
    }

    private mutating func tree() {
        let base = point(0.13, 0.69)
        let height = h * 0.34
        var trunk = Path()
        trunk.move(to: CGPoint(x: base.x - w * 0.018, y: base.y))
        trunk.addQuadCurve(to: CGPoint(x: base.x - w * 0.006, y: base.y - height * 0.6), control: CGPoint(x: base.x - w * 0.004, y: base.y - height * 0.3))
        trunk.addLine(to: CGPoint(x: base.x + w * 0.008, y: base.y - height * 0.6))
        trunk.addQuadCurve(to: CGPoint(x: base.x + w * 0.020, y: base.y), control: CGPoint(x: base.x + w * 0.006, y: base.y - height * 0.3))
        trunk.closeSubpath()
        context.fill(trunk, with: .color(tone(0.45, 0.31, 0.20, living: false)))

        let breathe = sin(time * 0.5) * 1.2
        let crown = CGPoint(x: base.x + breathe * 0.4, y: base.y - height * 0.72 + CGFloat(droop) * h * 0.012)
        let puffs: [(Double, Double, Double)] = [(0, 0, 1.0), (-0.85, 0.30, 0.74), (0.85, 0.28, 0.76), (-0.30, -0.62, 0.72), (0.42, -0.55, 0.70)]
        let radius = w * 0.082
        for (index, puff) in puffs.enumerated() {
            let rect = CGRect(
                x: crown.x + radius * puff.0 - radius * puff.2,
                y: crown.y + radius * puff.1 - radius * puff.2,
                width: radius * puff.2 * 2,
                height: radius * puff.2 * 2
            )
            let shade = index % 2 == 0 ? tone(0.28, 0.62, 0.32) : tone(0.34, 0.70, 0.36)
            context.fill(Path(ellipseIn: rect), with: .color(shade))
        }
        guard has(.blossom) else { return }
        for index in 0..<22 {
            let angle = scatter(index, 41) * 2 * .pi
            let reach = radius * 1.35 * sqrt(scatter(index, 42))
            let spot = CGRect(x: crown.x + cos(angle) * reach - 2.4, y: crown.y + sin(angle) * reach * 0.9 - 2.4, width: 4.8, height: 4.8)
            context.fill(Path(ellipseIn: spot), with: .color(tone(0.99, 0.78, 0.88, living: false)))
        }
        // A petal or two on the air.
        for index in 0..<5 {
            let fall = (time * 0.06 + scatter(index, 43)).truncatingRemainder(dividingBy: 1)
            let x = crown.x + radius * (scatter(index, 44) * 2.4 - 1.2) + sin(time + Double(index)) * 5
            let y = crown.y + (base.y - crown.y) * fall
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3.4, height: 2.4)), with: .color(tone(0.99, 0.80, 0.90, alpha: 1 - fall, living: false)))
        }
    }

    private mutating func koi() {
        let angle = time * 0.22
        let body = onWater(angle: angle, reach: 0.55)
        let heading = atan2(cos(angle) * Double(pondRadii.height), -sin(angle) * Double(pondRadii.width))
        var fish = Path()
        fish.addEllipse(in: CGRect(x: -w * 0.030, y: -h * 0.010, width: w * 0.060, height: h * 0.020))
        fish.move(to: CGPoint(x: -w * 0.028, y: 0))
        fish.addLine(to: CGPoint(x: -w * 0.050, y: -h * 0.012 + sin(time * 4) * 1.5))
        fish.addLine(to: CGPoint(x: -w * 0.050, y: h * 0.012 + sin(time * 4) * 1.5))
        fish.closeSubpath()
        let placed = fish
            .applying(CGAffineTransform(rotationAngle: heading))
            .applying(CGAffineTransform(translationX: body.x, y: body.y))
        context.fill(placed, with: .color(tone(0.98, 0.56, 0.24, alpha: 0.85, living: false)))
    }

    private mutating func firefliesOrDragonflies() {
        if timeOfDay == .night || timeOfDay == .dusk {
            for index in 0..<9 {
                let phase = Double(index) * 1.9
                let x = 0.12 + 0.76 * scatter(index, 51) + sin(time * 0.35 + phase) * 0.05
                let y = 0.40 + 0.34 * scatter(index, 52) + cos(time * 0.28 + phase) * 0.04
                let brightness = 0.35 + 0.65 * abs(sin(time * 1.3 + phase))
                let centre = point(x, y)
                glow(at: centre, radius: 15 * unit, color: Color(red: 1, green: 0.93, blue: 0.50), strength: 0.95 * brightness)
                softDisc(at: centre, radius: 1.7 * unit, color: Color(red: 1, green: 0.98, blue: 0.75).opacity(brightness))
            }
            return
        }
        for index in 0..<2 {
            let phase = Double(index) * 3.1
            let centre = point(0.35 + 0.35 * Double(index) + sin(time * 0.5 + phase) * 0.07, 0.60 + cos(time * 0.7 + phase) * 0.04)
            var bodyPath = Path()
            bodyPath.move(to: CGPoint(x: centre.x - 7, y: centre.y))
            bodyPath.addLine(to: CGPoint(x: centre.x + 7, y: centre.y))
            context.stroke(bodyPath, with: .color(tone(0.16, 0.52, 0.62, living: false)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let flutter = abs(sin(time * 9 + phase)) * 3
            for side in [-1.0, 1.0] {
                let wing = CGRect(x: centre.x - 1, y: centre.y + (side < 0 ? -6 - flutter : 0), width: 8, height: 6 + flutter)
                context.fill(Path(ellipseIn: wing), with: .color(.white.opacity(0.55)))
            }
        }
    }

    // MARK: Decorations

    private mutating func lantern() {
        let base = point(0.80, 0.715)
        var post = Path()
        post.move(to: base)
        post.addLine(to: CGPoint(x: base.x, y: base.y - h * 0.15))
        context.stroke(post, with: .color(tone(0.30, 0.24, 0.20, living: false)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        let box = CGRect(x: base.x - w * 0.022, y: base.y - h * 0.215, width: w * 0.044, height: h * 0.07)
        let lit = timeOfDay == .night || timeOfDay == .dusk
        if lit {
            let centre = CGPoint(x: box.midX, y: box.midY)
            let flame = Color(red: 1, green: 0.80, blue: 0.42)
            // The smallest flicker, the way a real flame never quite holds still.
            let flicker = 0.92 + 0.08 * sin(time * 6.1) * sin(time * 2.3 + 1)
            // Light spilling onto the grass under it.
            var pool = context
            pool.scaleBy(x: 1, y: 0.28)
            pool.translateBy(x: 0, y: base.y / 0.28 - base.y)
            let poolCentre = CGPoint(x: base.x, y: base.y)
            pool.fill(
                Path(ellipseIn: CGRect(x: poolCentre.x - w * 0.12, y: poolCentre.y - w * 0.12, width: w * 0.24, height: w * 0.24)),
                with: .radialGradient(Gradient(colors: [flame.opacity(0.45 * flicker), flame.opacity(0)]), center: poolCentre, startRadius: 0, endRadius: w * 0.12)
            )
            glow(at: centre, radius: w * 0.17, color: flame, strength: 0.65 * flicker)
            glow(at: centre, radius: w * 0.07, color: flame, strength: 0.80 * flicker)
        }
        context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(lit ? Color(red: 1, green: 0.86, blue: 0.52) : tone(0.95, 0.90, 0.78, living: false)))
        context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(tone(0.30, 0.24, 0.20, living: false)), lineWidth: 1.4)
    }

    private mutating func steppingStones() {
        for index in 0..<4 {
            let centre = onWater(angle: .pi * (0.30 + 0.13 * Double(index)), reach: 0.72)
            let rect = CGRect(x: centre.x - w * 0.026, y: centre.y - h * 0.010, width: w * 0.052, height: h * 0.020)
            context.fill(Path(ellipseIn: rect), with: .color(tone(0.66, 0.66, 0.68, living: false)))
        }
    }

    private mutating func paperBoat() {
        let bob = sin(time * 0.8) * 1.5
        let at = onWater(angle: 3.6 + sin(time * 0.1) * 0.2, reach: 0.45)
        var hull = Path()
        hull.move(to: CGPoint(x: at.x - w * 0.035, y: at.y + bob - h * 0.010))
        hull.addLine(to: CGPoint(x: at.x + w * 0.035, y: at.y + bob - h * 0.010))
        hull.addLine(to: CGPoint(x: at.x + w * 0.020, y: at.y + bob + h * 0.008))
        hull.addLine(to: CGPoint(x: at.x - w * 0.020, y: at.y + bob + h * 0.008))
        hull.closeSubpath()
        var sail = Path()
        sail.move(to: CGPoint(x: at.x, y: at.y + bob - h * 0.050))
        sail.addLine(to: CGPoint(x: at.x + w * 0.020, y: at.y + bob - h * 0.010))
        sail.addLine(to: CGPoint(x: at.x - w * 0.020, y: at.y + bob - h * 0.010))
        sail.closeSubpath()
        context.fill(sail, with: .color(tone(0.98, 0.98, 0.96, living: false)))
        context.fill(hull, with: .color(tone(0.90, 0.90, 0.88, living: false)))
    }

    private mutating func rubberDuck() {
        let bob = sin(time * 1.1 + 1) * 1.5
        let at = onWater(angle: 5.6, reach: 0.40)
        let yellow = tone(0.99, 0.84, 0.24, living: false)
        context.fill(Path(ellipseIn: CGRect(x: at.x - w * 0.028, y: at.y + bob - h * 0.018, width: w * 0.056, height: h * 0.030)), with: .color(yellow))
        context.fill(Path(ellipseIn: CGRect(x: at.x + w * 0.006, y: at.y + bob - h * 0.044, width: w * 0.030, height: w * 0.030)), with: .color(yellow))
        var beak = Path()
        beak.move(to: CGPoint(x: at.x + w * 0.034, y: at.y + bob - h * 0.030))
        beak.addLine(to: CGPoint(x: at.x + w * 0.048, y: at.y + bob - h * 0.026))
        beak.addLine(to: CGPoint(x: at.x + w * 0.034, y: at.y + bob - h * 0.020))
        beak.closeSubpath()
        context.fill(beak, with: .color(tone(0.97, 0.52, 0.18, living: false)))
        context.fill(Path(ellipseIn: CGRect(x: at.x + w * 0.022, y: at.y + bob - h * 0.036, width: 2.4, height: 2.4)), with: .color(.black.opacity(0.75)))
    }

    private mutating func mushrooms() {
        for (index, spot) in [(0.32, 0.975, 1.0), (0.36, 0.99, 0.7), (0.29, 0.995, 0.6)].enumerated() {
            let base = point(spot.0, spot.1)
            let size = w * 0.030 * spot.2
            context.fill(Path(roundedRect: CGRect(x: base.x - size * 0.22, y: base.y - size * 0.9, width: size * 0.44, height: size * 0.9), cornerRadius: size * 0.2), with: .color(tone(0.96, 0.93, 0.86, living: false)))
            var cap = Path()
            cap.addArc(center: CGPoint(x: base.x, y: base.y - size * 0.85), radius: size * 0.75, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            cap.closeSubpath()
            context.fill(cap, with: .color(tone(0.88, 0.26, 0.24, living: false)))
            let dot = CGRect(x: base.x - size * (index == 0 ? 0.35 : 0.1), y: base.y - size * 1.35, width: size * 0.26, height: size * 0.22)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.9)))
        }
    }

    private mutating func birdhouse() {
        let base = point(0.90, 0.67)
        var post = Path()
        post.move(to: base)
        post.addLine(to: CGPoint(x: base.x, y: base.y - h * 0.20))
        context.stroke(post, with: .color(tone(0.45, 0.33, 0.22, living: false)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        let house = CGRect(x: base.x - w * 0.030, y: base.y - h * 0.275, width: w * 0.060, height: h * 0.080)
        context.fill(Path(roundedRect: house, cornerRadius: 2), with: .color(tone(0.93, 0.80, 0.58, living: false)))
        var roof = Path()
        roof.move(to: CGPoint(x: house.minX - w * 0.010, y: house.minY))
        roof.addLine(to: CGPoint(x: house.midX, y: house.minY - h * 0.045))
        roof.addLine(to: CGPoint(x: house.maxX + w * 0.010, y: house.minY))
        roof.closeSubpath()
        context.fill(roof, with: .color(tone(0.78, 0.30, 0.26, living: false)))
        context.fill(Path(ellipseIn: CGRect(x: house.midX - w * 0.009, y: house.midY - w * 0.009, width: w * 0.018, height: w * 0.018)), with: .color(tone(0.28, 0.20, 0.16, living: false)))
    }

    private mutating func bridge() {
        let left = onWater(angle: .pi * 1.22, reach: 1.0)
        let right = onWater(angle: .pi * 1.78, reach: 1.0)
        let rise = h * 0.075
        var deck = Path()
        deck.move(to: left)
        deck.addQuadCurve(to: right, control: CGPoint(x: (left.x + right.x) / 2, y: min(left.y, right.y) - rise * 2))
        context.stroke(deck, with: .color(tone(0.62, 0.42, 0.28, living: false)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        var rail = Path()
        rail.move(to: CGPoint(x: left.x, y: left.y - h * 0.035))
        rail.addQuadCurve(to: CGPoint(x: right.x, y: right.y - h * 0.035), control: CGPoint(x: (left.x + right.x) / 2, y: min(left.y, right.y) - rise * 2 - h * 0.035))
        context.stroke(rail, with: .color(tone(0.72, 0.30, 0.26, living: false)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private mutating func balloon() {
        let centre = point(0.64 + sin(time * 0.2) * 0.01, 0.20 + cos(time * 0.35) * 0.012)
        let rx = w * 0.040, ry = w * 0.050
        var string = Path()
        string.move(to: CGPoint(x: centre.x, y: centre.y + ry))
        string.addQuadCurve(to: CGPoint(x: centre.x - w * 0.01, y: centre.y + ry + h * 0.12), control: CGPoint(x: centre.x + w * 0.02, y: centre.y + ry + h * 0.06))
        context.stroke(string, with: .color(tone(0.95, 0.95, 0.95, alpha: 0.8, living: false)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2)), with: .color(tone(0.95, 0.36, 0.42, living: false)))
        context.fill(Path(ellipseIn: CGRect(x: centre.x - rx * 0.55, y: centre.y - ry * 0.65, width: rx * 0.5, height: ry * 0.6)), with: .color(.white.opacity(0.35)))
    }

    private mutating func bunting() {
        let left = point(0.02, 0.06), right = point(0.98, 0.05)
        let sag = h * 0.10
        func along(_ t: Double) -> CGPoint {
            let x = left.x + (right.x - left.x) * t
            let y = left.y + (right.y - left.y) * t + sag * 4 * t * (1 - t)
            return CGPoint(x: x, y: y)
        }
        var line = Path()
        line.move(to: left)
        for step in 1...20 { line.addLine(to: along(Double(step) / 20)) }
        context.stroke(line, with: .color(tone(0.95, 0.95, 0.95, alpha: 0.9, living: false)), lineWidth: 1.2)
        let colours: [(Double, Double, Double)] = [(0.96, 0.42, 0.42), (0.99, 0.80, 0.32), (0.40, 0.74, 0.92), (0.52, 0.80, 0.46)]
        for index in 0..<11 {
            let a = along((Double(index) + 0.15) / 11), b = along((Double(index) + 0.85) / 11)
            let flap = sin(time * 1.5 + Double(index)) * 1.5
            var flag = Path()
            flag.move(to: a)
            flag.addLine(to: b)
            flag.addLine(to: CGPoint(x: (a.x + b.x) / 2 + flap, y: (a.y + b.y) / 2 + h * 0.055))
            flag.closeSubpath()
            let colour = colours[index % colours.count]
            context.fill(flag, with: .color(tone(colour.0, colour.1, colour.2, living: false)))
        }
    }

    // MARK: Weather

    private mutating func precipitation() {
        guard weather == .rain || weather == .snow else { return }
        let isSnow = weather == .snow
        for index in 0..<Int(Double(isSnow ? 34 : 46) * min(2, 1 + headroom / h)) {
            let speed = isSnow ? 0.10 + 0.06 * scatter(index, 61) : 0.9 + 0.5 * scatter(index, 61)
            let fall = (time * speed + scatter(index, 62)).truncatingRemainder(dividingBy: 1)
            let x = w * scatter(index, 63) + (isSnow ? sin(time + Double(index)) * 6 : -fall * 14)
            let y = (h + headroom + footroom) * fall - headroom
            if isSnow {
                let flake = 2.0 + 2.0 * scatter(index, 64)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: flake, height: flake)), with: .color(.white.opacity(0.85)))
            } else {
                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(x: x - 3, y: y + 10))
                context.stroke(streak, with: .color(Color(red: 0.80, green: 0.88, blue: 0.98).opacity(0.55)), lineWidth: 1.1)
            }
        }
    }
}

#Preview("A year, thriving, dusk") {
    WorldSceneView(
        state: WorldState(goalDays: 365, vitality: 1),
        decorations: WorldDecoration.allCases,
        timeOfDay: .dusk
    )
    .frame(height: 320)
}

#Preview("Two weeks, wilting, rain") {
    WorldSceneView(state: WorldState(goalDays: 16, vitality: 0.1), timeOfDay: .day, weather: .rain)
        .frame(height: 320)
}
