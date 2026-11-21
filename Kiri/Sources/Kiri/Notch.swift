import AppKit
import Combine
import SwiftUI

// MARK: Notch detection

struct NotchInfo {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat
    let simulated: Bool

    /// The real notch on this screen, if it has one.
    static func real(on screen: NSScreen? = NSScreen.main) -> NotchInfo? {
        guard let s = screen, s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        return NotchInfo(screen: s, width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top, simulated: false)
    }

    /// A pretend notch for Macs without one (for demos), the size of a 14" MacBook Pro notch.
    static func simulated(on screen: NSScreen? = NSScreen.main) -> NotchInfo? {
        guard let s = screen else { return nil }
        let menuBar = max(24, s.frame.maxY - s.visibleFrame.maxY)
        return NotchInfo(screen: s, width: 185, height: menuBar, simulated: true)
    }
}

enum DisplayMode: String, CaseIterable {
    case auto, notch, desktop
    var title: String {
        switch self {
        case .auto: return "Auto (notch if this Mac has one)"
        case .notch: return "Notch (simulate if no notch)"
        case .desktop: return "Desktop pet"
        }
    }
}

// MARK: Shape

/// The black island: flush with the top of the screen, little outward curves where it meets the
/// menu bar (like the real notch), and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = 10

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, f = flare, R = min(bottomRadius, (w - 2 * f) / 2, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - R))
        p.addQuadCurve(to: CGPoint(x: f + R, y: h), control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: w - f - R, y: h))
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - R), control: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: Layout

enum NotchLayout {
    static let flare: CGFloat = 10
    static let chatHeight: CGFloat = 440

    static func islandSize(_ n: NotchInfo, expanded: Bool) -> CGSize {
        expanded ? CGSize(width: max(n.width + 200, 400), height: n.height + 150)
                 : CGSize(width: n.width + 96, height: n.height + peek)
    }

    /// How much of the collapsed island shows below the notch (where the owl peeks out).
    static let peek: CGFloat = 46
}

// MARK: Controller

@MainActor
final class NotchController {
    let state: PetState
    let notch: NotchInfo
    let panel: PetPanel
    private var bag: Set<AnyCancellable> = []
    private var hoverCollapse: DispatchWorkItem?

    init(state: PetState, notch: NotchInfo) {
        self.state = state
        self.notch = notch
        panel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        let host = ClickThroughHostingView(rootView: NotchRootView(state: state, controller: self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout(animated: true) }
            .store(in: &bag)
        layout(animated: false)
        RenderGate.shared.watch(panel)
    }

    var expanded: Bool {
        state.notchHover || state.chatOpen || state.busy || state.testing || state.offerFix
            || state.bubble != nil || state.mood == .happy
    }

    var totalSize: CGSize {
        let island = NotchLayout.islandSize(notch, expanded: expanded)
        let width = state.chatOpen ? max(island.width, 420) : island.width
        return CGSize(width: width, height: island.height + (state.chatOpen ? NotchLayout.chatHeight + 8 : 0))
    }

    func layout(animated: Bool) {
        let size = totalSize
        let f = notch.screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
        PetGeometry.frame = frame
        if state.chatOpen {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
    }

    func hover(_ inside: Bool) {
        hoverCollapse?.cancel()
        if inside {
            if !state.notchHover { state.notchHover = true }
        } else {
            let work = DispatchWorkItem { [weak self] in self?.state.notchHover = false }
            hoverCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func show() { panel.orderFrontRegardless(); RenderGate.shared.refresh() }
    func hide() { panel.orderOut(nil); RenderGate.shared.refresh() }
}

// MARK: Views

struct NotchRootView: View {
    @ObservedObject var state: PetState
    let controller: NotchController

    var body: some View {
        let expanded = controller.expanded
        let size = NotchLayout.islandSize(controller.notch, expanded: expanded)
        VStack(spacing: 8) {
            NotchIsland(state: state, notch: controller.notch, expanded: expanded)
                .frame(width: size.width, height: size.height)
                .onHover { controller.hover($0) }
                .onTapGesture { state.petTapped() }
                .contextMenu { NotchMenu(state: state) }
            if state.chatOpen {
                ChatView(state: state)
                    .frame(width: 420, height: NotchLayout.chatHeight)
                    .environment(\.colorScheme, .dark)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: expanded)
    }
}

struct NotchMenu: View {
    @ObservedObject var state: PetState
    var body: some View {
        Button(state.chatOpen ? "Close chat" : "Open chat") { state.chatOpen.toggle() }
        Button("Run tests") { state.runTests() }
        Button("Choose project…") { state.chooseProject() }
        Divider()
        Button("Quit Kiri") { NSApp.terminate(nil) }
    }
}

struct NotchIsland: View {
    @ObservedObject var state: PetState
    let notch: NotchInfo
    let expanded: Bool
    @ObservedObject private var gate = RenderGate.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: gate.interval(for: state.mood), paused: gate.paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: expanded ? 34 : 18, flare: NotchLayout.flare)
                    .fill(Color.black)
                    .overlay(
                        NotchShape(bottomRadius: expanded ? 34 : 18, flare: NotchLayout.flare)
                            .stroke(OwlArt.accent.opacity(glowOpacity(t)), lineWidth: 1.2)
                    )

                if expanded {
                    expandedContent(t)
                        .padding(.top, notch.height)
                        .transition(.opacity)
                } else {
                    collapsedContent(t)
                        .transition(.opacity)
                }
            }
            .clipShape(NotchShape(bottomRadius: expanded ? 34 : 18, flare: NotchLayout.flare))
        }
    }

    private func glowOpacity(_ t: Double) -> Double {
        switch state.mood {
        case .working, .thinking: return 0.45 + 0.4 * sin(t * 5)
        case .happy: return 0.9
        case .sad: return 0.3
        default: return expanded ? 0.35 : 0.0
        }
    }

    // Collapsed: the owl peeks up from the bottom edge of the island, under the camera.
    private func collapsedContent(_ t: Double) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
            // below the camera: head, eyes and beak peek up from the island's bottom edge
            NotchOwl(mood: state.mood, t: t, height: 96)
                .offset(y: 3 + sin(t * 1.6) * 1.5)
                .frame(height: NotchLayout.peek, alignment: .top)
                .clipped()
            HStack {
                Circle().fill(statusColor).frame(width: 7, height: 7).shadow(color: statusColor, radius: 4)
                    .opacity(state.mood == .idle ? 0 : 1)
                Spacer()
            }
            .padding(.horizontal, NotchLayout.flare + 14)
            .padding(.bottom, 12)
        }
        .drawingGroup()
    }

    private var statusColor: Color {
        switch state.mood {
        case .working, .thinking: return Color(red: 0.4, green: 0.8, blue: 1)
        case .happy: return .green
        case .sad: return .red
        case .sleepy: return .purple
        case .idle: return .clear
        }
    }

    // Expanded: big owl in the middle, mood effects around, a status line underneath.
    private func expandedContent(_ t: Double) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                switch state.mood {
                case .working:
                    SoundWaves(t: t, color: Color(red: 0.4, green: 0.8, blue: 1), spread: 150, bars: 11).offset(y: -44)
                case .happy:
                    Confetti(t: t, width: 340, height: 110).offset(y: -50)
                case .sleepy:
                    Zzz(t: t, color: OwlArt.accent, x: 70, y: -60)
                case .thinking:
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(OwlArt.accent).frame(width: 6, height: 6).offset(y: sin(t * 6 - Double(i)) * 3)
                        }
                    }
                    .offset(x: 84, y: -70)
                default: EmptyView()
                }
                NotchOwl(mood: state.mood, t: t, height: 150)
                    .frame(height: 104, alignment: .top)
                    .clipped()
            }
            .frame(height: 104)
            .drawingGroup()

            statusLine
                .padding(.horizontal, 26)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if state.offerFix {
            HStack(spacing: 8) {
                Text("Tests failed").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Button("Fix it") { state.fixTests() }.buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                Button("Not now") { state.dismissFix() }.buttonStyle(.bordered).controlSize(.small)
            }
        } else {
            Text(state.bubble ?? state.activity ?? defaultLine)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var defaultLine: String {
        switch state.mood {
        case .sleepy: return "It's late… 😴"
        case .happy: return "Nice work! 🎉"
        default: return state.projectURL.map { "Watching \($0.lastPathComponent) · click to chat" } ?? "Click me to chat"
        }
    }
}

/// The owl, posed for the notch: upper body, cut off by the island edge.
struct NotchOwl: View {
    let mood: Mood
    let t: Double
    let height: CGFloat

    var body: some View {
        let pose = OwlArt.pose(for: mood)
        Group {
            if pose == "body" {
                // reuse the desktop owl (with blinking fur eyelids), framed on the head
                OwlFrame(mood: mood == .sad || mood == .sleepy || mood == .thinking ? mood : .idle, t: t, headOnly: true)
                    .frame(height: height)
            } else if let img = ImageArt.image("owl", named: pose) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(height: height * 0.74)
            }
        }
        .id(pose)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: pose)
    }
}

// MARK: Static preview of the notch states (`Kiri --notch-sheet out.png`)

enum NotchSheet {
    @MainActor
    static func render(to url: URL) {
        guard let base = NotchInfo.simulated() else { return }
        let notch = NotchInfo(screen: base.screen, width: 185, height: 32, simulated: true)
        func make(_ title: String, mood: Mood, expanded: Bool, bubble: String? = nil, busy: Bool = false) -> some View {
            let s = PetState()
            s.mood = mood
            s.bubble = bubble
            s.busy = busy
            if busy { s.activity = "Running tests…" }
            let size = NotchLayout.islandSize(notch, expanded: expanded)
            return VStack(spacing: 10) {
                ZStack(alignment: .top) {
                    // fake menu bar + desktop
                    LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.3), Color(red: 0.08, green: 0.09, blue: 0.16)],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: notch.height)
                    NotchIsland(state: s, notch: notch, expanded: expanded)
                        .frame(width: size.width, height: size.height)
                    Circle().fill(Color(white: 0.12)).frame(width: 8, height: 8).offset(y: 12)  // camera
                }
                .frame(width: 520, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
            }
        }
        let sheet = VStack(spacing: 22) {
            HStack(spacing: 22) {
                make("Idle (collapsed)", mood: .idle, expanded: false)
                make("Hover / greeting", mood: .idle, expanded: true, bubble: "Hi, I'm Hoot! Ready to help 🦉")
            }
            HStack(spacing: 22) {
                make("Working (expanded)", mood: .working, expanded: true, busy: true)
                make("Tests passed (expanded)", mood: .happy, expanded: true, bubble: "All tests passed! 🎉")
            }
            HStack(spacing: 22) {
                make("Thinking (collapsed)", mood: .thinking, expanded: false)
                make("Sleepy (collapsed)", mood: .sleepy, expanded: false)
            }
        }
        .padding(26)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("failed"); return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
