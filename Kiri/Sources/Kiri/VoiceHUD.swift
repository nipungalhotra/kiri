import SwiftUI

/// What Hoot's voice is doing right now, for the glowing ring around it and the notch.
@MainActor
final class VoiceHUD: ObservableObject {
    static let shared = VoiceHUD()
    enum Mode: Equatable { case idle, listening, thinking, speaking }

    @Published var speaking = false
    /// When the last spoken word started (the ring pulses with each word).
    var lastWord = Date.distantPast
    /// When "Hey Hoot" was last heard (a bright ring flashes outward).
    @Published var wokeAt = Date.distantPast

    static var enabled: Bool { UserDefaults.standard.object(forKey: "voiceRing") as? Bool ?? true }

    func mode(listening: Bool, busy: Bool) -> Mode {
        if listening { return .listening }
        if speaking { return .speaking }
        if busy { return .thinking }
        return .idle
    }

    /// 0…1: how loud right now (mic while listening, words while speaking).
    func level(_ mode: Mode, at now: Date) -> Double {
        switch mode {
        case .listening: return Double(VoiceInput.shared.level)
        case .speaking: return max(0.18, exp(-now.timeIntervalSince(lastWord) * 4.5))
        default: return 0
        }
    }
}

/// The live ring behind Hoot: ripples while listening, a circle of sound bars while speaking,
/// slow spinning arcs while thinking, and a flash when it hears its name.
struct HootHalo: View {
    @ObservedObject var state: PetState
    @ObservedObject private var hud = VoiceHUD.shared
    @ObservedObject private var mic = VoiceInput.shared
    @ObservedObject private var gate = RenderGate.shared

    var body: some View {
        let mode = hud.mode(listening: mic.listening, busy: state.busy)
        let flashing = Date().timeIntervalSince(hud.wokeAt) < 1
        if VoiceHUD.enabled, mode != .idle || flashing {
            TimelineView(.animation(minimumInterval: gate.lowPower ? 1.0 / 12 : 1.0 / 30, paused: gate.paused)) { ctx in
                let now = ctx.date
                HaloCanvas(mode: hud.mode(listening: mic.listening, busy: state.busy),
                           t: now.timeIntervalSinceReferenceDate,
                           level: hud.level(hud.mode(listening: mic.listening, busy: state.busy), at: now),
                           flash: now.timeIntervalSince(hud.wokeAt))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Draws one frame of the halo (pure, so it can be rendered for screenshots).
struct HaloCanvas: View {
    let mode: VoiceHUD.Mode
    let t: Double
    let level: Double
    /// Seconds since "Hey Hoot" was heard.
    var flash: Double = 99
    var radius: CGFloat = 90

    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let pink = Color(red: 0.93, green: 0.45, blue: 0.85)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
            let spin = Gradient(colors: [Self.purple, Self.cyan, Self.pink, Self.purple])
            let shading = GraphicsContext.Shading.conicGradient(spin, center: c, angle: .radians(t * 1.2))

            // soft glow behind everything
            if mode != .idle {
                let glowR = radius * (1.05 + 0.12 * level)
                ctx.fill(circle(glowR), with: .radialGradient(
                    Gradient(colors: [Self.purple.opacity(0.0), Self.purple.opacity(0.10 + 0.18 * level), Self.cyan.opacity(0.0)]),
                    center: c, startRadius: glowR * 0.55, endRadius: glowR * 1.25))
            }

            switch mode {
            case .listening:
                // ripples flowing outward, stronger when you speak louder
                for i in 0..<3 {
                    let p = (t * 0.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let r = radius + CGFloat(p) * 22
                    ctx.stroke(circle(r), with: .color(Self.cyan.opacity((1 - p) * (0.25 + 0.5 * level))), lineWidth: 1.5)
                }
                // the main ring breathes with your voice
                let r = radius + CGFloat(level) * 12
                var glow = ctx
                glow.addFilter(.blur(radius: 6))
                glow.stroke(circle(r), with: shading, lineWidth: 6)
                ctx.stroke(circle(r), with: shading, lineWidth: 2.5)

            case .speaking:
                // a circle of sound bars, like a voice equaliser, pulsing with each word
                let n = 56
                var bars = Path()
                for i in 0..<n {
                    let a = Double(i) / Double(n) * 2 * .pi
                    let wobble = abs(sin(t * 8 + Double(i) * 0.9)) * 0.6 + abs(sin(t * 5.3 - Double(i) * 1.7)) * 0.4
                    let len = 3 + CGFloat(level * (5 + 13 * wobble))
                    let inner = radius - 2
                    bars.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                    bars.addLine(to: CGPoint(x: c.x + cos(a) * (inner + len), y: c.y + sin(a) * (inner + len)))
                }
                var glow = ctx
                glow.addFilter(.blur(radius: 5))
                glow.stroke(bars, with: shading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                ctx.stroke(bars, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.stroke(circle(radius - 6), with: .color(Self.purple.opacity(0.35)), lineWidth: 1)

            case .thinking:
                // two arcs spinning in opposite directions
                for (i, span) in [(0, 100.0), (1, 60.0)] {
                    let dir = i == 0 ? 1.0 : -1.4
                    let start = Angle.degrees(t * 90 * dir + Double(i) * 180)
                    var arc = Path()
                    arc.addArc(center: c, radius: radius + CGFloat(i) * 7, startAngle: start, endAngle: start + .degrees(span), clockwise: false)
                    var glow = ctx
                    glow.addFilter(.blur(radius: 5))
                    glow.stroke(arc, with: shading, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    ctx.stroke(arc, with: shading, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                ctx.stroke(circle(radius), with: .color(Self.purple.opacity(0.3)), lineWidth: 1)

            case .idle:
                break
            }

            // "Hey Hoot" heard: one bright ring bursts outward
            if flash < 1 {
                let p = flash
                ctx.stroke(circle(radius * (0.7 + 0.6 * CGFloat(p))), with: .color(Self.cyan.opacity(1 - p)), lineWidth: 4 * (1 - p) + 1)
            }
        }
    }
}

/// Small live sound bars for the notch (listening or speaking).
struct VoiceBars: View {
    let mode: VoiceHUD.Mode
    let t: Double
    let level: Double
    var count = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { i in
                let wobble = abs(sin(t * 9 + Double(i) * 1.3))
                let h = 4 + (mode == .thinking ? 2 * wobble : 14 * level * (0.4 + 0.6 * wobble))
                Capsule()
                    .fill(LinearGradient(colors: [HaloCanvas.purple, HaloCanvas.cyan], startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: h)
            }
        }
        .frame(height: 18)
    }
}
