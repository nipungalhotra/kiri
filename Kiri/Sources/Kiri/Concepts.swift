import AppKit
import SwiftUI

// Three alternative character concepts, rendered side by side so the user can pick one.

// MARK: A — Orbi: a glass orb with a glowing LED dot-matrix face

struct OrbiFrame: View {
    let mood: Mood
    let t: Double

    static let faces: [Mood: [String]] = [
        .idle:     ["...........", "..##...##..", "..##...##..", "...........", "....###....", "..........."],
        .thinking: ["...##...##.", "...##...##.", "...........", "...........", ".....##....", "..........."],
        .working:  ["...........", "..###.###..", "...........", "...........", "....###....", "..........."],
        .happy:    ["...........", "...#...#...", "..#.#.#.#..", "...........", "...#...#...", "....###...."],
        .sad:      ["...........", "..##...##..", "..##...##..", "...........", "....###....", "...#...#..."],
        .sleepy:   ["...........", "...........", "..###.###..", "...........", ".....#.....", "..........."],
    ]

    private var glow: Color {
        switch mood {
        case .happy: return Color(red: 0.55, green: 1.0, blue: 0.75)
        case .sad: return Color(red: 0.45, green: 0.65, blue: 1.0)
        case .sleepy: return Color(red: 0.65, green: 0.55, blue: 1.0)
        case .working: return Color(red: 1.0, green: 0.78, blue: 0.35)
        default: return Color(red: 0.37, green: 0.95, blue: 1.0)
        }
    }

    var body: some View {
        let hover = sin(t * 2) * 3
        ZStack {
            Ellipse().fill(glow.opacity(0.35)).frame(width: 70, height: 12).blur(radius: 6).offset(y: 62)
            ZStack {
                // back half of the ring + the dot when it's behind the orb
                ring.opacity(0.6)
                if sin(t * 1.4) < 0 { ringDot }
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.29), Color(red: 0.04, green: 0.06, blue: 0.10)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 70))
                    .frame(width: 104, height: 104)
                Circle()
                    .stroke(LinearGradient(colors: [glow.opacity(0.9), .clear, glow.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    .frame(width: 104, height: 104)
                dotFace
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: 58, height: 26).offset(x: -14, y: -32)
                // front (lower) half of the ring passes below the face
                frontRing
                if sin(t * 1.4) >= 0 { ringDot }
                if mood == .thinking || mood == .working {
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(glow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 114, height: 114)
                        .rotationEffect(.degrees(t * (mood == .working ? 360 : 180)))
                        .shadow(color: glow, radius: 4)
                }
            }
            .offset(y: hover)
            if mood == .sleepy {
                ForEach(0..<3, id: \.self) { i in
                    let ph = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z").font(.system(size: 10 + CGFloat(ph) * 10, weight: .bold, design: .rounded))
                        .foregroundStyle(glow)
                        .offset(x: 44 + ph * 16, y: -40 - ph * 30).opacity(1 - ph)
                }
            }
        }
        .frame(width: 160, height: 150)
    }

    private var ringAngle: Double { -12 }
    private var ringBase: some View {
        Ellipse().stroke(glow.opacity(0.5), lineWidth: 1.4)
            .frame(width: 146, height: 30)
            .rotationEffect(.degrees(ringAngle))
    }
    private var ring: some View { ringBase.offset(y: 30) }
    /// Only the lower half, drawn over the orb so the ring looks like it wraps around it.
    private var frontRing: some View {
        ringBase
            .frame(width: 160, height: 60)
            .mask(VStack(spacing: 0) { Color.clear.frame(height: 30); Color.black.frame(height: 30) })
            .offset(y: 30)
    }
    private var ringDot: some View {
        let a = t * 1.4
        let x = cos(a) * 73, y = sin(a) * 15
        let r = ringAngle * .pi / 180
        return Circle().fill(glow).frame(width: 6, height: 6).shadow(color: glow, radius: 4)
            .offset(x: x * cos(r) - y * sin(r), y: x * sin(r) + y * cos(r) + 30)
    }

    private var dotFace: some View {
        let rows = Self.faces[mood] ?? Self.faces[.idle]!
        return VStack(spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 3) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, ch in
                        Circle()
                            .fill(ch == "#" ? glow : Color.white.opacity(0.06))
                            .frame(width: 4.5, height: 4.5)
                            .shadow(color: ch == "#" ? glow : .clear, radius: 3)
                    }
                }
            }
        }
        .offset(y: 4)
    }
}

// MARK: B — Wisp: a little living flame of aurora light

struct WispShape: Shape {
    var sway: Double
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: h))
        p.addCurve(to: CGPoint(x: w * 0.96, y: h * 0.58), control1: CGPoint(x: w * 0.82, y: h), control2: CGPoint(x: w * 0.96, y: h * 0.82))
        p.addCurve(to: CGPoint(x: w * (0.58 + sway), y: 0), control1: CGPoint(x: w * 0.96, y: h * 0.34), control2: CGPoint(x: w * 0.72, y: h * 0.2))
        p.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.58), control1: CGPoint(x: w * 0.42, y: h * 0.24), control2: CGPoint(x: w * 0.04, y: h * 0.34))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h), control1: CGPoint(x: w * 0.04, y: h * 0.82), control2: CGPoint(x: w * 0.18, y: h))
        p.closeSubpath()
        return p
    }
}

struct WispFrame: View {
    let mood: Mood
    let t: Double

    private var colors: [Color] {
        switch mood {
        case .happy: return [Color(red: 1, green: 0.92, blue: 0.45), Color(red: 1, green: 0.55, blue: 0.4), Color(red: 1, green: 0.35, blue: 0.6)]
        case .sad: return [Color(red: 0.6, green: 0.85, blue: 1), Color(red: 0.35, green: 0.5, blue: 1), Color(red: 0.3, green: 0.3, blue: 0.8)]
        case .sleepy: return [Color(red: 0.8, green: 0.7, blue: 1), Color(red: 0.5, green: 0.4, blue: 0.9), Color(red: 0.25, green: 0.2, blue: 0.55)]
        default: return [Color(red: 0.6, green: 1, blue: 0.9), Color(red: 0.35, green: 0.75, blue: 1), Color(red: 0.65, green: 0.4, blue: 1)]
        }
    }

    var body: some View {
        let sway = sin(t * 2.4) * 0.06
        let bob = sin(t * 1.8) * 4
        ZStack {
            WispShape(sway: sway).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 118).blur(radius: 14).opacity(0.8)
            WispShape(sway: sway).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 84, height: 106)
            WispShape(sway: sway * 1.4).fill(Color.white.opacity(0.35))
                .frame(width: 40, height: 56).offset(x: -6, y: 18).blur(radius: 6)
            eyes.offset(y: 22)
            ForEach(0..<4, id: \.self) { i in
                let ph = (t * 0.5 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                Circle().fill(colors[0]).frame(width: 4, height: 4).shadow(color: colors[0], radius: 3)
                    .offset(x: sin(Double(i) * 2.1 + t) * 40, y: 40 - ph * 100).opacity(1 - ph)
            }
        }
        .offset(y: bob)
        .frame(width: 160, height: 150)
    }

    @ViewBuilder private var eyes: some View {
        HStack(spacing: 18) {
            ForEach(0..<2, id: \.self) { _ in
                switch mood {
                case .happy:
                    ArcShape(up: true).stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 12, height: 7).shadow(color: .white, radius: 4)
                case .sleepy:
                    ArcShape(up: false).stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 12, height: 5)
                default:
                    let blink = t.truncatingRemainder(dividingBy: 3.8) < 0.12
                    Capsule().fill(Color.white)
                        .frame(width: 9, height: blink ? 2 : (mood == .sad ? 9 : (mood == .working ? 6 : 15)))
                        .shadow(color: .white, radius: 5)
                        .offset(x: mood == .thinking ? 3 : 0, y: mood == .thinking ? -4 : 0)
                }
            }
        }
    }
}

// MARK: C — Termi: a tiny living terminal window with an ASCII face

struct TermiFrame: View {
    let mood: Mood
    let t: Double

    static let faces: [Mood: String] = [
        .idle: "•‿•", .thinking: "•_•", .working: "⌐■_■", .happy: "^▽^", .sad: "╥﹏╥", .sleepy: "-_-",
    ]

    private var accent: Color {
        switch mood {
        case .happy: return Color(red: 0.45, green: 1, blue: 0.55)
        case .sad: return Color(red: 0.5, green: 0.7, blue: 1)
        case .sleepy: return Color(red: 0.7, green: 0.6, blue: 1)
        case .working: return Color(red: 1, green: 0.8, blue: 0.35)
        default: return Color(red: 0.4, green: 0.95, blue: 0.65)
        }
    }

    var body: some View {
        let bob = sin(t * 2.2) * 3
        let cursorOn = t.truncatingRemainder(dividingBy: 1) < 0.55
        ZStack {
            Ellipse().fill(Color.black.opacity(0.35)).frame(width: 80, height: 10).blur(radius: 4).offset(y: 56)
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.2)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 0.2, green: 0.8, blue: 0.3)).frame(width: 7, height: 7)
                    Spacer()
                    Text("kiri").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                VStack(spacing: 4) {
                    Text("{ \(Self.faces[mood] ?? "•‿•") }")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .shadow(color: accent.opacity(0.8), radius: 6)
                    HStack(spacing: 2) {
                        Text(mood == .sleepy ? "$ zzz" : "$").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Rectangle().fill(accent).frame(width: 6, height: 11).opacity(cursorOn ? 1 : 0)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 124, height: 88)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.07, green: 0.08, blue: 0.11)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.5), lineWidth: 1.2))
            .shadow(color: accent.opacity(0.35), radius: 12)
            .rotationEffect(.degrees(mood == .happy ? sin(t * 8) * 4 : 0))
            .offset(y: bob)
        }
        .frame(width: 160, height: 150)
    }
}

enum ConceptSheet {
    @MainActor
    static func render(to url: URL) {
        let moods: [Mood] = Mood.allCases
        func row<V: View>(_ title: String, _ subtitle: String, @ViewBuilder _ make: @escaping (Mood) -> V) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    ForEach(moods, id: \.self) { m in
                        VStack(spacing: 0) {
                            make(m)
                            Text(m.rawValue).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 22) {
            row("Hoot moods", "Live eyes: thinking looks up, working reads, sad looks down") { OwlFrame(mood: $0, t: 2.1, followMouse: false) }
            row("Hoot talking", "Beak opens and closes while Kiri speaks") { m in
                let i = Double(Mood.allCases.firstIndex(of: m) ?? 0)
                OwlFrame(mood: .idle, t: 1.05 + i * 0.037, followMouse: false, lookOverride: CGPoint(x: 0, y: 0.1), previewTalking: true)
            }
            row("Hoot looking around", "Eyes follow your mouse: left · right · up · down · close · far") { m in
                let looks: [Mood: CGPoint] = [.idle: CGPoint(x: -1, y: 0), .thinking: CGPoint(x: 1, y: 0), .working: CGPoint(x: 0, y: -1),
                                              .happy: CGPoint(x: 0, y: 1), .sad: CGPoint(x: -0.6, y: 0.6), .sleepy: CGPoint(x: 0.7, y: -0.6)]
                OwlFrame(mood: .idle, t: 1.0, followMouse: false, lookOverride: looks[m])
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.17), Color(red: 0.06, green: 0.07, blue: 0.10)],
                                   startPoint: .top, endPoint: .bottom))
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
