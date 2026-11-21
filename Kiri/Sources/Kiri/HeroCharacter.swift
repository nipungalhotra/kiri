import AppKit
import SwiftUI

/// Where the pet window is on screen, so the hero can turn toward the mouse.
@MainActor
enum PetGeometry {
    static var frame: NSRect = .zero
}

/// Full-body character standing on a holographic platform.
/// Uses `<name>/body.png` (transparent cutout) plus the per-mood face PNGs as emote bubbles.
struct HeroFrame: View {
    let name: String
    let accent: Color
    let mood: Mood
    let t: Double
    /// Turn toward the mouse (off for static renders).
    var followMouse = true

    static let size = CGSize(width: 210, height: 290)
    private let bodyHeight: CGFloat = 214

    var body: some View {
        let body = ImageArt.image(name, named: "body")
        let jump = mood == .happy ? -abs(sin(t * 4.2)) * 16 : 0
        let sink: CGFloat = mood == .sleepy ? 6 : (mood == .sad ? 3 : 0)
        let breathe = 1 + sin(t * (mood == .sleepy ? 1.0 : 2.0)) * 0.008
        let tilt = followMouse ? mouseTilt : 0
        let glitch = mood == .sad && t.truncatingRemainder(dividingBy: 1.7) < 0.16

        ZStack(alignment: .bottom) {
            beam
            platform.offset(y: -14)
            particles

            if let body {
                ZStack {
                    // soft accent aura behind the silhouette
                    silhouette(body).foregroundStyle(accent).blur(radius: 10).opacity(mood == .sleepy ? 0.25 : 0.55)
                    if glitch {
                        hero(body).colorMultiply(.red).blendMode(.screen).offset(x: -4).opacity(0.7)
                        hero(body).colorMultiply(.cyan).blendMode(.screen).offset(x: 4).opacity(0.7)
                    }
                    hero(body)
                        .saturation(mood == .sad ? 0.7 : 1)
                        .brightness(mood == .sleepy ? -0.22 : 0)
                        .offset(x: glitch ? CGFloat(sin(t * 90)) * 3 : 0)
                    if mood == .working || mood == .thinking { scanline(body) }
                    if mood == .happy { silhouette(body).foregroundStyle(.white).opacity(max(0, 0.35 - abs(sin(t * 4.2)) * 0.6)) }
                }
                .frame(height: bodyHeight)
                .scaleEffect(x: 1, y: breathe, anchor: .bottom)
                .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .offset(y: -22 + jump + sink)
            } else {
                Text("missing \(name)/body.png").font(.caption).foregroundStyle(.white)
                    .padding(8).background(Color.black.opacity(0.7)).offset(y: -100)
            }

            moodProp
            emote
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
    }

    // MARK: Body helpers

    private func hero(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
    }

    private func silhouette(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().renderingMode(.template).interpolation(.high).scaledToFit()
    }

    /// A band of light sweeping up through the body, clipped to the character.
    private func scanline(_ img: NSImage) -> some View {
        let p = (t * (mood == .working ? 0.9 : 0.5)).truncatingRemainder(dividingBy: 1)
        return LinearGradient(colors: [.clear, accent.opacity(0.85), .white.opacity(0.9), accent.opacity(0.85), .clear],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: 26)
            .offset(y: bodyHeight / 2 - CGFloat(p) * bodyHeight)
            .frame(height: bodyHeight)
            .mask(hero(img))
            .blendMode(.screen)
    }

    private var mouseTilt: Double {
        let m = NSEvent.mouseLocation
        let f = PetGeometry.frame
        guard f.width > 0 else { return 0 }
        let dx = (m.x - f.midX) / 500
        return Double(max(-1, min(1, dx))) * 16
    }

    // MARK: Stage

    private var platform: some View {
        let speed = mood == .working ? 140.0 : (mood == .sleepy ? 8.0 : 30.0)
        let dim = mood == .sleepy ? 0.4 : 1.0
        return ZStack {
            Ellipse().fill(RadialGradient(colors: [accent.opacity(0.55), accent.opacity(0.08), .clear],
                                          center: .center, startRadius: 2, endRadius: 80))
                .frame(width: 170, height: 40)
            Ellipse().stroke(accent.opacity(0.9), lineWidth: 2).frame(width: 128, height: 26)
                .shadow(color: accent, radius: 6)
            Ellipse()
                .stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [10, 7], dashPhase: t * speed))
                .frame(width: 156, height: 34)
            Ellipse()
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 9], dashPhase: -t * speed * 0.6))
                .frame(width: 100, height: 19)
        }
        .opacity(dim)
    }

    private var beam: some View {
        LinearGradient(colors: [accent.opacity(mood == .sleepy ? 0.05 : 0.22), .clear], startPoint: .bottom, endPoint: .top)
            .frame(width: 130, height: 200)
            .mask(Trapezoid().frame(width: 130, height: 200))
            .offset(y: -20)
    }

    private var particles: some View {
        let count = mood == .happy ? 16 : (mood == .sleepy ? 4 : 9)
        let speed = mood == .happy ? 0.9 : (mood == .working ? 0.6 : 0.3)
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let seed = Double(i) * 12.9898
                let ph = (t * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                let x = sin(seed) * 62 + sin(t * 1.3 + seed) * 6
                Circle()
                    .fill(i % 3 == 0 ? Color.white : accent)
                    .frame(width: i % 4 == 0 ? 4 : 2.5, height: i % 4 == 0 ? 4 : 2.5)
                    .shadow(color: accent, radius: 3)
                    .offset(x: x, y: -20 - ph * (mood == .happy ? 240 : 190))
                    .opacity(sin(ph * .pi))
            }
        }
    }

    // MARK: Mood props

    @ViewBuilder private var moodProp: some View {
        switch mood {
        case .working: codeWindow.offset(x: 64, y: -150)
        case .sleepy: Zzz(t: t, color: accent, x: 30, y: -232)
        case .sad:
            ForEach(0..<7, id: \.self) { i in
                let ph = (t * 1.2 + Double(i) * 0.31).truncatingRemainder(dividingBy: 1)
                Capsule().fill(accent.opacity(0.6)).frame(width: 1.5, height: 10)
                    .offset(x: -54 + CGFloat(i) * 18, y: -250 + ph * 210)
                    .opacity(1 - ph)
            }
        default: EmptyView()
        }
    }

    /// Floating holographic code panel with lines being "typed".
    private var codeWindow: some View {
        let widths: [CGFloat] = [46, 30, 54, 22, 40, 50, 26, 36, 44]
        let colors: [Color] = [accent, .white.opacity(0.8), Color(red: 1, green: 0.8, blue: 0.4), accent.opacity(0.7)]
        let k = Int(t * 2.5)
        let typing = CGFloat((t * 2.5).truncatingRemainder(dividingBy: 1))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(accent.opacity(0.7)).frame(width: 4, height: 4) }
                Spacer()
                Text("</>").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(accent)
            }
            ForEach(0..<5, id: \.self) { i in
                let idx = (i + k) % widths.count
                HStack(spacing: 3) {
                    Capsule().fill(colors[(idx + 1) % colors.count].opacity(0.6)).frame(width: 8, height: 3)
                    Capsule().fill(colors[idx % colors.count]).frame(width: widths[idx] * (i == 4 ? typing : 1), height: 3)
                }
                .padding(.leading, CGFloat((idx % 3) * 5))
            }
        }
        .padding(8)
        .frame(width: 88, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.75), lineWidth: 1))
        .shadow(color: accent.opacity(0.6), radius: 8)
        .rotation3DEffect(.degrees(-22), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(y: sin(t * 2) * 3)
    }

    /// Small round face showing the expression, popping in beside the head.
    @ViewBuilder private var emote: some View {
        if mood != .idle, let face = ImageArt.image(name, mood) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6)).frame(width: 50, height: 50)
                Image(nsImage: face).resizable().interpolation(.high).scaledToFill()
                    .frame(width: 46, height: 46).clipShape(Circle())
                Circle().stroke(accent, lineWidth: 2).frame(width: 48, height: 48).shadow(color: accent, radius: 5)
                if mood == .thinking {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(accent).frame(width: 4, height: 4).offset(y: sin(t * 6 - Double(i)) * 2)
                        }
                    }
                    .padding(4).background(Capsule().fill(Color.black.opacity(0.8)))
                    .offset(x: 22, y: -26)
                }
            }
            .offset(x: -66, y: -206 + sin(t * 2.4) * 3)
            .id(mood)
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
    }
}

struct Trapezoid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.3, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.3, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
