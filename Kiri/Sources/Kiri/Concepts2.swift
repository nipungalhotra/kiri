import SwiftUI

// Four more characters: Nimbus (cloud), Bubbles (soap bubble), Prism (crystal), Iris (robot eye).

/// Simple shared eyes + mouth used by a few characters.
struct SimpleFace: View {
    let mood: Mood
    let t: Double
    var ink: Color
    var spacing: CGFloat = 22
    var glow: Bool = false

    private var blinking: Bool { t.truncatingRemainder(dividingBy: 4.1) < 0.12 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: spacing) { eye; eye }
            mouth
        }
        .shadow(color: glow ? ink : .clear, radius: 4)
    }

    @ViewBuilder private var eye: some View {
        switch mood {
        case .happy:
            ArcShape(up: true).stroke(ink, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 11, height: 7)
        case .sleepy:
            ArcShape(up: false).stroke(ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).frame(width: 11, height: 5)
        default:
            Capsule().fill(ink)
                .frame(width: 8, height: blinking ? 2 : (mood == .sad ? 8 : (mood == .working ? 6 : 12)))
                .offset(x: mood == .thinking ? 2 : 0, y: mood == .thinking ? -3 : 0)
        }
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .happy: BowlShape().fill(ink).frame(width: 14, height: 8)
        case .sad: ArcShape(up: true).stroke(ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).frame(width: 10, height: 4)
        case .sleepy: Ellipse().fill(ink).frame(width: 5, height: 5 + sin(t * 1.1))
        case .thinking: Capsule().fill(ink).frame(width: 7, height: 2.5).offset(x: 3)
        default: ArcShape(up: false).stroke(ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).frame(width: 10, height: 4)
        }
    }
}

/// Floating "z"s for sleepy mode.
struct Zzz: View {
    let t: Double
    var color: Color
    var x: CGFloat = 40, y: CGFloat = -36
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ph = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z").font(.system(size: 10 + CGFloat(ph) * 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .offset(x: x + ph * 16, y: y - ph * 30).opacity(1 - ph)
            }
        }
    }
}

// MARK: Nimbus — a cloud whose weather is its mood

struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 130, sy = r.height / 90
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: r.minX + x * sx, y: r.minY + y * sy, width: w * sx, height: h * sy)
        }
        var p = Path()
        p.addEllipse(in: rect(8, 34, 52, 52))
        p.addEllipse(in: rect(32, 4, 68, 68))
        p.addEllipse(in: rect(74, 28, 50, 50))
        p.addRoundedRect(in: rect(8, 48, 116, 40), cornerSize: CGSize(width: 20 * sx, height: 20 * sy))
        return p
    }
}

struct CloudFrame: View {
    let mood: Mood
    let t: Double

    private var tint: [Color] {
        switch mood {
        case .sad: return [Color(red: 0.74, green: 0.78, blue: 0.84), Color(red: 0.48, green: 0.53, blue: 0.62)]
        case .sleepy: return [Color(red: 0.6, green: 0.64, blue: 0.82), Color(red: 0.36, green: 0.38, blue: 0.6)]
        default: return [.white, Color(red: 0.80, green: 0.87, blue: 0.97)]
        }
    }

    var body: some View {
        let bob = sin(t * 1.6) * 3
        ZStack {
            if mood == .happy { sun.offset(x: 40, y: -34) }
            if mood == .sleepy { moon.offset(x: -44, y: -38) }

            CloudShape()
                .fill(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom))
                .frame(width: 130, height: 90)
                .shadow(color: tint[1].opacity(0.6), radius: 10, y: 4)
            SimpleFace(mood: mood, t: t, ink: Color(red: 0.2, green: 0.24, blue: 0.34)).offset(y: 14)

            switch mood {
            case .sad:
                ForEach(0..<6, id: \.self) { i in
                    let ph = (t * 1.3 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                    Capsule().fill(Color(red: 0.45, green: 0.7, blue: 1))
                        .frame(width: 3, height: 10)
                        .offset(x: -40 + CGFloat(i) * 16, y: 52 + ph * 30)
                        .opacity(1 - ph)
                }
            case .working:
                BoltShape().fill(Color(red: 1, green: 0.85, blue: 0.2))
                    .frame(width: 16, height: 26)
                    .shadow(color: .yellow, radius: 6)
                    .offset(x: 52, y: -30)
                    .opacity(sin(t * 9) > -0.3 ? 1 : 0.2)
            case .thinking:
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white).frame(width: 6 + CGFloat(i) * 3, height: 6 + CGFloat(i) * 3)
                        .offset(x: 50 + CGFloat(i) * 8, y: -26 - CGFloat(i) * 12 + sin(t * 3 + Double(i)) * 2)
                }
            case .sleepy:
                Zzz(t: t, color: Color(red: 0.75, green: 0.78, blue: 1), x: 44, y: -30)
            default: EmptyView()
            }
        }
        .offset(y: bob)
        .frame(width: 160, height: 150)
    }

    private var sun: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(Color(red: 1, green: 0.78, blue: 0.25)).frame(width: 3, height: 9)
                    .offset(y: -29)
                    .rotationEffect(.degrees(Double(i) * 45 + t * 30))
            }
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.4), Color(red: 1, green: 0.6, blue: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
                .frame(width: 40, height: 40)
                .shadow(color: .orange.opacity(0.6), radius: 8)
        }
    }

    private var moon: some View {
        Circle().fill(Color(red: 1, green: 0.95, blue: 0.75))
            .frame(width: 28, height: 28)
            .mask {
                ZStack {
                    Rectangle()
                    Circle().frame(width: 24, height: 24).offset(x: 9, y: -6).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .shadow(color: Color(red: 1, green: 0.95, blue: 0.7).opacity(0.7), radius: 6)
    }
}

struct BoltShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pts: [(CGFloat, CGFloat)] = [(0.6, 0), (0.05, 0.58), (0.45, 0.58), (0.3, 1), (0.95, 0.38), (0.55, 0.38), (0.75, 0)]
        p.move(to: CGPoint(x: r.minX + pts[0].0 * r.width, y: r.minY + pts[0].1 * r.height))
        for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: r.minX + pt.0 * r.width, y: r.minY + pt.1 * r.height)) }
        p.closeSubpath()
        return p
    }
}

// MARK: Bubbles — a wobbly iridescent soap bubble

struct BubbleFrame: View {
    let mood: Mood
    let t: Double

    private var tint: Color {
        switch mood {
        case .happy: return Color(red: 1, green: 0.7, blue: 0.85)
        case .sad: return Color(red: 0.5, green: 0.65, blue: 1)
        case .sleepy: return Color(red: 0.6, green: 0.5, blue: 0.9)
        default: return Color(red: 0.55, green: 0.9, blue: 1)
        }
    }

    var body: some View {
        let speed = mood == .sleepy ? 1.2 : 2.6
        let wob = sin(t * speed)
        let sag = mood == .sad ? 0.9 : 1.0
        let bob = mood == .happy ? -abs(sin(t * 3.5)) * 10 : sin(t * 1.5) * 4
        let rainbow = [Color(red: 1, green: 0.5, blue: 0.75), Color(red: 1, green: 0.9, blue: 0.4),
                       Color(red: 0.4, green: 1, blue: 0.85), Color(red: 0.5, green: 0.6, blue: 1),
                       Color(red: 1, green: 0.5, blue: 0.75)]
        ZStack {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.28), tint.opacity(0.32)], center: .init(x: 0.4, y: 0.35),
                                         startRadius: 6, endRadius: 60))
                Circle().stroke(AngularGradient(colors: rainbow, center: .center, angle: .degrees(t * 50)), lineWidth: 10)
                    .blur(radius: 5).opacity(0.5)
                Circle().stroke(AngularGradient(colors: rainbow, center: .center, angle: .degrees(-t * 35)), lineWidth: 2.5)
                Ellipse().fill(Color.white.opacity(0.8)).frame(width: 26, height: 12)
                    .rotationEffect(.degrees(-35)).offset(x: -26, y: -30)
                Circle().fill(Color.white.opacity(0.6)).frame(width: 6, height: 6).offset(x: 30, y: 28)
                SimpleFace(mood: mood, t: t, ink: Color(red: 0.18, green: 0.18, blue: 0.36), spacing: 20).offset(y: 6)
            }
            .frame(width: 104, height: 104)
            .scaleEffect(x: (1 + wob * 0.045) / sag, y: (1 - wob * 0.045) * sag, anchor: .bottom)

            switch mood {
            case .happy, .working:
                ForEach(0..<5, id: \.self) { i in
                    let ph = (t * 0.6 + Double(i) / 5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(AngularGradient(colors: rainbow, center: .center), lineWidth: 1.2)
                        .frame(width: 8 + CGFloat(i % 3) * 4, height: 8 + CGFloat(i % 3) * 4)
                        .offset(x: (i % 2 == 0 ? -1 : 1) * (56 + sin(t + Double(i)) * 6), y: 40 - ph * 100)
                        .opacity(1 - ph)
                }
            case .thinking:
                ForEach(0..<3, id: \.self) { i in
                    Circle().stroke(tint, lineWidth: 1.5).frame(width: 6 + CGFloat(i) * 4, height: 6 + CGFloat(i) * 4)
                        .offset(x: 52 + CGFloat(i) * 8, y: -38 - CGFloat(i) * 11 + sin(t * 3 + Double(i)) * 2)
                }
            case .sad:
                let ph = (t * 0.7).truncatingRemainder(dividingBy: 1)
                Ellipse().fill(tint.opacity(0.8)).frame(width: 6, height: 9).offset(y: 52 + ph * 18).opacity(1 - ph)
            case .sleepy:
                Zzz(t: t, color: tint, x: 46, y: -40)
            case .idle: EmptyView()
            }
        }
        .offset(y: bob)
        .frame(width: 160, height: 150)
    }
}

// MARK: Prism — a slowly turning crystal with a glowing face

struct GemShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0.25, 0)); p.addLine(to: pt(0.75, 0)); p.addLine(to: pt(1, 0.3))
        p.addLine(to: pt(0.5, 1)); p.addLine(to: pt(0, 0.3)); p.closeSubpath()
        return p
    }
}

struct GemFacets: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0, 0.3)); p.addLine(to: pt(1, 0.3))
        p.move(to: pt(0.25, 0)); p.addLine(to: pt(0.36, 0.3)); p.addLine(to: pt(0.5, 1))
        p.move(to: pt(0.75, 0)); p.addLine(to: pt(0.64, 0.3)); p.addLine(to: pt(0.5, 1))
        p.move(to: pt(0.5, 0)); p.addLine(to: pt(0.36, 0.3))
        p.move(to: pt(0.5, 0)); p.addLine(to: pt(0.64, 0.3))
        return p
    }
}

struct PrismFrame: View {
    let mood: Mood
    let t: Double

    private var tint: [Color] {
        switch mood {
        case .happy: return [Color(red: 1, green: 0.88, blue: 0.5), Color(red: 1, green: 0.45, blue: 0.7)]
        case .sad: return [Color(red: 0.6, green: 0.7, blue: 0.95), Color(red: 0.28, green: 0.32, blue: 0.7)]
        case .sleepy: return [Color(red: 0.62, green: 0.56, blue: 0.86), Color(red: 0.24, green: 0.2, blue: 0.5)]
        case .working: return [Color(red: 0.6, green: 1, blue: 0.8), Color(red: 0.15, green: 0.65, blue: 0.6)]
        default: return [Color(red: 0.6, green: 0.92, blue: 1), Color(red: 0.45, green: 0.38, blue: 1)]
        }
    }

    var body: some View {
        let spin = mood == .working ? 3.0 : (mood == .sleepy ? 0.4 : 1.1)
        let turn = 0.86 + 0.14 * cos(t * spin)
        let bob = mood == .happy ? -abs(sin(t * 4)) * 10 : sin(t * 1.8) * 4
        ZStack {
            Ellipse().fill(tint[1].opacity(0.4)).frame(width: 60, height: 10).blur(radius: 6).offset(y: 64)
            ZStack {
                GemShape().fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottom))
                GemShape().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                center: .center, angle: .degrees(t * 40)))
                    .opacity(0.22).blendMode(.screen)
                GemFacets().stroke(Color.white.opacity(0.45), lineWidth: 1)
                GemShape().stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                SimpleFace(mood: mood, t: t, ink: .white, spacing: 18, glow: true)
                    .scaleEffect(0.9).offset(y: -4)
            }
            .frame(width: 98, height: 112)
            .scaleEffect(x: turn, y: 1)
            .shadow(color: tint[1].opacity(0.7), radius: 12)
            .offset(y: bob)

            ForEach(0..<4, id: \.self) { i in
                let a = Double(i) * 1.57 + t * 0.8
                Text("✦").font(.system(size: 9 + CGFloat(i % 2) * 4))
                    .foregroundStyle(i % 2 == 0 ? tint[0] : .white)
                    .offset(x: cos(a) * 62, y: sin(a) * 46)
                    .opacity(mood == .sleepy ? 0.25 : 0.5 + 0.5 * sin(t * 3 + Double(i)))
            }
            if mood == .sleepy { Zzz(t: t, color: tint[0], x: 44, y: -44) }
        }
        .frame(width: 160, height: 150)
    }
}

// MARK: Iris — one big expressive robot eye

struct IrisFrame: View {
    let mood: Mood
    let t: Double

    private var irisColors: [Color] {
        switch mood {
        case .happy: return [Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.95, green: 0.45, blue: 0.2)]
        case .sad: return [Color(red: 0.55, green: 0.75, blue: 1), Color(red: 0.2, green: 0.3, blue: 0.75)]
        case .sleepy: return [Color(red: 0.7, green: 0.6, blue: 1), Color(red: 0.3, green: 0.2, blue: 0.6)]
        case .working: return [Color(red: 0.5, green: 1, blue: 0.75), Color(red: 0.1, green: 0.55, blue: 0.45)]
        default: return [Color(red: 0.45, green: 0.95, blue: 1), Color(red: 0.1, green: 0.45, blue: 0.75)]
        }
    }

    private var look: CGSize {
        switch mood {
        case .thinking: return CGSize(width: 9, height: -11)
        case .working: return CGSize(width: sin(t * 2.2) * 13, height: 2)
        case .sad: return CGSize(width: 0, height: 9)
        case .sleepy: return CGSize(width: 0, height: 6)
        default: return CGSize(width: sin(t * 0.7) * 5, height: cos(t * 0.9) * 3)
        }
    }

    private var pupil: CGFloat {
        switch mood {
        case .happy: return 11
        case .sad: return 19
        case .working: return 9 + CGFloat(sin(t * 6)) * 1.5
        default: return 15 + CGFloat(sin(t * 1.3)) * 1.5
        }
    }

    private var upperLid: CGFloat {
        let blink = t.truncatingRemainder(dividingBy: 4.4) < 0.14
        if blink && mood != .sleepy { return 1 }
        switch mood {
        case .sleepy: return 0.62 + CGFloat(sin(t * 1.1)) * 0.05
        case .sad: return 0.34
        case .working: return 0.22
        case .happy: return 0.12
        default: return 0.08
        }
    }

    var body: some View {
        let bob = mood == .happy ? -abs(sin(t * 4)) * 8 : sin(t * 1.8) * 3
        let lid = LinearGradient(colors: [Color(red: 0.26, green: 0.29, blue: 0.36), Color(red: 0.14, green: 0.16, blue: 0.21)],
                                 startPoint: .top, endPoint: .bottom)
        ZStack {
            Ellipse().fill(irisColors[1].opacity(0.4)).frame(width: 70, height: 10).blur(radius: 6).offset(y: 64)
            ZStack {
                // metal casing
                Circle().fill(AngularGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.9), Color(white: 0.4), Color(white: 0.85)],
                                              center: .center))
                    .frame(width: 112, height: 112)
                Circle().fill(Color(red: 0.1, green: 0.11, blue: 0.14)).frame(width: 100, height: 100)
                // eyeball
                ZStack {
                    Circle().fill(RadialGradient(colors: [.white, Color(white: 0.82)], center: .center, startRadius: 20, endRadius: 50))
                    ZStack {
                        Circle().fill(RadialGradient(colors: irisColors, center: .center, startRadius: 4, endRadius: 24))
                            .frame(width: 46, height: 46)
                        ForEach(0..<12, id: \.self) { i in
                            Capsule().fill(Color.white.opacity(0.18)).frame(width: 1.2, height: 9)
                                .offset(y: -15).rotationEffect(.degrees(Double(i) * 30))
                        }
                        Circle().fill(Color.black).frame(width: pupil, height: pupil)
                        Circle().fill(Color.white.opacity(0.9)).frame(width: 7, height: 7).offset(x: -8, y: -8)
                        Circle().fill(Color.white.opacity(0.6)).frame(width: 3, height: 3).offset(x: 7, y: 6)
                    }
                    .offset(look)
                    // upper lid (curved edge)
                    Ellipse().fill(lid).frame(width: 140, height: 92 * upperLid * 2)
                        .offset(y: -46)
                        .rotationEffect(.degrees(mood == .sad ? -12 : 0))
                    // lower lid rises into a smile when happy
                    if mood == .happy {
                        Ellipse().fill(lid).frame(width: 140, height: 92 * 0.36 * 2).offset(y: 46)
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                Circle().stroke(irisColors[0].opacity(0.7), lineWidth: 1.5).frame(width: 100, height: 100)
                    .shadow(color: irisColors[0], radius: 5)
            }
            .offset(y: bob)

            switch mood {
            case .happy:
                ForEach(0..<4, id: \.self) { i in
                    let a = Double(i) * 1.57 + t * 1.2
                    Text("✦").font(.system(size: 11)).foregroundStyle(irisColors[0])
                        .offset(x: cos(a) * 70, y: sin(a) * 50).opacity(0.5 + 0.5 * sin(t * 4 + Double(i)))
                }
            case .thinking:
                Circle().trim(from: 0, to: 0.2).stroke(irisColors[0], style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 124, height: 124).rotationEffect(.degrees(t * 200)).offset(y: bob)
            case .sleepy:
                Zzz(t: t, color: irisColors[0], x: 48, y: -46)
            default: EmptyView()
            }
        }
        .frame(width: 160, height: 150)
    }
}
