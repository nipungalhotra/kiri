import SwiftUI

/// Kiri's moods. Each one changes colour, face, motion and the little extras around it.
enum Mood: String, CaseIterable {
    case idle, thinking, working, happy, sad, sleepy
}

/// Which body Kiri wears.
enum CharacterStyle: String, CaseIterable, Identifiable {
    case owl, codex, muse, orbi, wisp, termi, iris, nimbus, bubbles, prism, sprout
    var id: String { rawValue }
    /// Full-body characters are taller than the small mascots.
    var isHero: Bool { self == .codex || self == .muse || self == .owl }
    var title: String {
        switch self {
        case .owl: return "Hoot"
        case .codex: return "Codex"
        case .muse: return "Muse"
        case .orbi: return "Orbi"
        case .wisp: return "Wisp"
        case .termi: return "Termi"
        case .iris: return "Iris"
        case .nimbus: return "Nimbus"
        case .bubbles: return "Bubbles"
        case .prism: return "Prism"
        case .sprout: return "Sprout (classic)"
        }
    }
    var blurb: String {
        switch self {
        case .owl: return "Purple owl · notch companion"
        case .codex: return "Your art · engineering agent"
        case .muse: return "Your art · creative agent"
        case .orbi: return "Glass orb · LED dot face"
        case .wisp: return "Aurora flame · sparks"
        case .termi: return "Living terminal · ASCII face"
        case .iris: return "One big robot eye"
        case .nimbus: return "Cloud · weather = mood"
        case .bubbles: return "Wobbly rainbow bubble"
        case .prism: return "Turning crystal · glow face"
        case .sprout: return "The original blob"
        }
    }
}

/// How often Kiri redraws. Drawing every display frame (60fps) with blurs and glows overloaded
/// WindowServer on a MacBook Air, so frames are capped per mood and paused when Kiri can't be seen.
@MainActor
final class RenderGate: ObservableObject {
    static let shared = RenderGate()
    /// True when every Kiri window is hidden or fully covered.
    @Published var paused = false
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RenderGate.shared.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    func interval(for mood: Mood) -> Double {
        var fps: Double
        switch mood {
        case .sleepy: fps = 8
        case .idle, .sad: fps = 15
        case .thinking, .working, .happy: fps = 24
        }
        if lowPower { fps = min(fps, 10) }
        return 1 / fps
    }

    private var windows: [WeakWindow] = []
    private struct WeakWindow { weak var window: NSWindow? }

    /// Pause drawing whenever none of Kiri's windows is actually on screen.
    func watch(_ window: NSWindow) {
        windows.append(WeakWindow(window: window))
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { RenderGate.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        let anyVisible = windows.contains { w in
            guard let win = w.window else { return false }
            return win.isVisible && win.occlusionState.contains(.visible)
        }
        if paused == anyVisible { paused = !anyVisible }
    }
}

/// The animated character. `leaves` grows with the passing-tests streak (1...3).
struct KiriCharacter: View {
    let mood: Mood
    var leaves: Int = 1
    var style: CharacterStyle = .orbi
    @ObservedObject private var gate = RenderGate.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: gate.interval(for: mood), paused: gate.paused)) { context in
            frame(t: context.date.timeIntervalSinceReferenceDate)
                // Render all the glows, blurs and masks inside Kiri on the GPU as one flat image,
                // so WindowServer only has a single layer to composite.
                .drawingGroup()
        }
    }

    @ViewBuilder private func frame(t: Double) -> some View {
            switch style {
            case .owl:
                OwlFrame(mood: mood, t: t)
            case .codex:
                HeroFrame(name: "codex", accent: Color(red: 0.2, green: 0.9, blue: 1), mood: mood, t: t)
            case .muse:
                HeroFrame(name: "muse", accent: Color(red: 0.72, green: 0.45, blue: 1), mood: mood, t: t)
            case .orbi: OrbiFrame(mood: mood, t: t)
            case .wisp: WispFrame(mood: mood, t: t)
            case .termi: TermiFrame(mood: mood, t: t)
            case .iris: IrisFrame(mood: mood, t: t)
            case .nimbus: CloudFrame(mood: mood, t: t)
            case .bubbles: BubbleFrame(mood: mood, t: t)
            case .prism: PrismFrame(mood: mood, t: t)
            case .sprout: KiriFrame(mood: mood, leaves: leaves, t: t)
            }
    }
}

/// One frame of Kiri at time `t`. Pure function of its inputs, so it can also be rendered to PNG.
struct KiriFrame: View {
    let mood: Mood
    let leaves: Int
    let t: Double

    private let ink = Color(red: 0.12, green: 0.16, blue: 0.22)

    private var palette: (top: Color, bottom: Color) {
        switch mood {
        case .happy:  return (Color(red: 0.80, green: 1.00, blue: 0.62), Color(red: 0.18, green: 0.74, blue: 0.52))
        case .sad:    return (Color(red: 0.66, green: 0.80, blue: 0.97), Color(red: 0.27, green: 0.45, blue: 0.78))
        case .sleepy: return (Color(red: 0.58, green: 0.64, blue: 0.86), Color(red: 0.27, green: 0.30, blue: 0.58))
        default:      return (Color(red: 0.58, green: 0.97, blue: 0.82), Color(red: 0.13, green: 0.66, blue: 0.65))
        }
    }

    /// Vertical offset: happy hops, sad sinks, sleepy barely breathes, others gently bob.
    private var hop: Double {
        switch mood {
        case .happy:  return -abs(sin(t * 5.5)) * 14
        case .sleepy: return sin(t * 1.1) * 1.5
        case .sad:    return sin(t * 1.4) * 1.5 + 4
        default:      return sin(t * 2.2) * 3.5
        }
    }

    /// Horizontal squash (vertical is the inverse) for a soft, jelly feel.
    private var squash: Double {
        if mood == .happy { return 1 + (1 - abs(sin(t * 5.5))) * 0.08 }
        return 1 + sin(t * (mood == .sleepy ? 1.1 : 2.2)) * 0.02
    }

    private var blinking: Bool {
        let period = mood == .working ? 2.6 : 4.3
        return t.truncatingRemainder(dividingBy: period) < 0.13
    }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.18))
                .frame(width: 70 * (1 + hop / 60), height: 10)
                .blur(radius: 3)
                .offset(y: 50)

            ZStack {
                sprout.offset(y: -52)
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .fill(LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: 92, height: 80)
                    .overlay(
                        Ellipse()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 30, height: 14)
                            .rotationEffect(.degrees(-20))
                            .offset(x: -22, y: -24)
                    )
                    .shadow(color: palette.bottom.opacity(0.5), radius: 8, y: 4)
                cheeks
                eyes.offset(y: -4)
                mouth.offset(y: 16)
            }
            .scaleEffect(x: squash, y: 2 - squash, anchor: .bottom)
            .rotationEffect(.degrees(mood == .thinking ? sin(t * 1.5) * 4 + 4 : 0))
            .offset(y: hop)

            extras
        }
        .frame(width: 150, height: 140)
    }

    // MARK: Parts

    private var sprout: some View {
        let sway = sin(t * 1.6) * (mood == .happy ? 14 : 7)
        return ZStack(alignment: .bottom) {
            Capsule().fill(Color(red: 0.25, green: 0.6, blue: 0.3)).frame(width: 3.5, height: 18)
            leaf(angle: -40).offset(x: -7, y: -12)
            if leaves >= 2 { leaf(angle: 40).offset(x: 7, y: -9) }
            if leaves >= 3 {
                Circle().fill(Color(red: 1, green: 0.75, blue: 0.3)).frame(width: 8, height: 8).offset(y: -18)
            }
        }
        .frame(width: 30, height: 30, alignment: .bottom)
        .rotationEffect(.degrees(sway), anchor: .bottom)
        .opacity(mood == .sleepy ? 0.8 : 1)
    }

    private func leaf(angle: Double) -> some View {
        Ellipse()
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.9, blue: 0.4), Color(red: 0.25, green: 0.65, blue: 0.3)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 13, height: 7)
            .rotationEffect(.degrees(angle))
    }

    private var cheeks: some View {
        HStack(spacing: 50) {
            ForEach(0..<2, id: \.self) { _ in
                Ellipse()
                    .fill(Color(red: 1, green: 0.55, blue: 0.6).opacity(mood == .happy ? 0.75 : 0.45))
                    .frame(width: 12, height: 7)
            }
        }
        .offset(y: 8)
    }

    private var eyes: some View {
        HStack(spacing: 26) { eye(left: true); eye(left: false) }
    }

    @ViewBuilder private func eye(left: Bool) -> some View {
        switch mood {
        case .happy:
            ArcShape(up: true)
                .stroke(ink, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 13, height: 8)
        case .sleepy:
            ArcShape(up: false)
                .stroke(ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 13, height: 6)
        default:
            let look: CGSize = mood == .thinking ? CGSize(width: 2.5, height: -3)
                : (mood == .working ? CGSize(width: sin(t * 3) * 2.5, height: 3) : .zero)
            ZStack {
                Capsule().fill(ink)
                Circle().fill(Color.white).frame(width: 4, height: 4).offset(x: 2, y: -3).opacity(blinking ? 0 : 1)
            }
            .frame(width: 11, height: blinking ? 2 : (mood == .sad ? 11 : 15))
            .offset(look)
            .overlay(alignment: .top) {
                if mood == .sad {
                    Capsule().fill(ink).frame(width: 12, height: 2.5)
                        .rotationEffect(.degrees(left ? -18 : 18))
                        .offset(y: -7)
                }
            }
        }
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .happy:
            ZStack {
                BowlShape().fill(ink)
                Ellipse().fill(Color(red: 1, green: 0.5, blue: 0.55)).frame(width: 9, height: 4).offset(y: 2.5)
            }
            .frame(width: 18, height: 10)
            .clipShape(BowlShape())
        case .sad:
            ArcShape(up: true).stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 12, height: 5).offset(y: 3)
        case .sleepy:
            Ellipse().fill(ink).frame(width: 6, height: 6 + sin(t * 1.1) * 1.5)
        case .thinking:
            Capsule().fill(ink).frame(width: 8, height: 2.5).offset(x: 4)
        default:
            ArcShape(up: false).stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 12, height: 5)
        }
    }

    @ViewBuilder private var extras: some View {
        switch mood {
        case .happy:
            ForEach(0..<5, id: \.self) { i in
                let a = Double(i) / 5 * 2 * .pi + t * 1.2
                Text("✦")
                    .font(.system(size: 11 + CGFloat(i % 2) * 5))
                    .foregroundStyle(i % 2 == 0 ? Color.yellow : Color.pink)
                    .offset(x: cos(a) * 66, y: sin(a) * 40 - 10)
                    .opacity(0.6 + 0.4 * sin(t * 4 + Double(i)))
            }
        case .sleepy:
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 10 + CGFloat(phase) * 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.6, blue: 0.95))
                    .offset(x: 36 + phase * 18, y: -30 - phase * 34)
                    .opacity(1 - phase)
            }
        case .thinking:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(ink.opacity(0.7)).frame(width: 6, height: 6)
                        .offset(y: sin(t * 6 - Double(i)) * 3)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.92)))
            .offset(x: 52, y: -48)
        case .working:
            Text("</>")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(palette.bottom)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.92)))
                .offset(x: 52, y: -44 + sin(t * 5) * 2)
        case .sad:
            let phase = (t * 0.6).truncatingRemainder(dividingBy: 1)
            Ellipse().fill(Color(red: 0.5, green: 0.75, blue: 1)).frame(width: 5, height: 8)
                .offset(x: -20, y: 6 + phase * 22 + hop)
                .opacity(1 - phase)
        case .idle:
            EmptyView()
        }
    }
}

/// `up == true` draws "^", otherwise a "u"-ish curve.
struct ArcShape: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.6))
        }
        return p
    }
}

/// Flat top, round bottom: an open, laughing mouth.
struct BowlShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: 2 * r.maxY - r.minY))
        p.closeSubpath()
        return p
    }
}
