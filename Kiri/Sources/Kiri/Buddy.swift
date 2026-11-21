import AppKit
import SwiftUI

/// A second, smaller pet that sits next to Hoot and looks after the tests: it works while they run,
/// cheers when they pass, worries when they fail, and banters with the owl. Click it to run the tests.
/// 🦉 → Buddy Pet. Desktop mode only.
@MainActor
final class BuddyState: ObservableObject {
    @Published var mood: Mood = .idle
    @Published var bubble: String?
    @Published var style: CharacterStyle
    private var token = 0

    init(style: CharacterStyle) { self.style = style }

    func say(_ text: String, mood m: Mood? = nil, for seconds: Double = 4) {
        if let m { mood = m }
        bubble = text
        token += 1
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.token == t else { return }
            self.bubble = nil
            if self.mood != .working { self.mood = .idle }
        }
    }
}

enum BuddyEvent {
    case testsStarted, testsPassed(streak: Int), testsFailed, owlHappy, owlThinking, owlIdle
}

@MainActor
final class BuddyController {
    static let size = NSSize(width: 150, height: 230)
    static let styles: [CharacterStyle] = [.orbi, .sprout, .nimbus, .wisp, .bubbles, .iris, .termi, .prism]

    let state: BuddyState
    let panel: PetPanel
    private weak var owlPanel: NSWindow?
    private weak var pet: PetState?
    private var observer: NSObjectProtocol?

    init(style: CharacterStyle, owlPanel: NSWindow, pet: PetState) {
        state = BuddyState(style: style)
        self.owlPanel = owlPanel
        self.pet = pet
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = ClickThroughHostingView(rootView: BuddyView(state: state) { [weak pet] in pet?.runTests() })
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        RenderGate.shared.watch(panel)
        follow()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: owlPanel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: owlPanel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        panel.orderFrontRegardless()
        state.say("Hi Hoot! I'll watch the tests 🧪", for: 4)
    }

    /// Sit just left of the owl (which is the bottom-right part of its window).
    func follow() {
        guard let f = owlPanel?.frame else { return }
        let owlLeft = f.maxX - PetWindowController.compact.width
        panel.setFrameOrigin(NSPoint(x: owlLeft - Self.size.width + 30, y: f.minY + 4))
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        panel.orderOut(nil)
        RenderGate.shared.refresh()
    }

    func react(_ e: BuddyEvent) {
        switch e {
        case .testsStarted:
            state.mood = .working
            state.bubble = "On it! 🧪"
        case .testsPassed(let streak):
            let lines = ["Told you it'd pass! 🎉", "Green! High five, Hoot! ✋", "All good on my side ✅", "\(streak) in a row, wow! 🔥"]
            state.say(lines[streak > 2 ? 3 : streak % 3], mood: .happy, for: 5)
            if Int.random(in: 0..<3) == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.pet?.say("Teamwork! 🦉🤝", for: 3) }
            }
        case .testsFailed:
            state.say(["Uh oh… red 😟", "Hoot, can you fix this one?", "Something broke 💥"].randomElement()!, mood: .sad, for: 6)
        case .owlHappy:
            if state.mood == .idle { state.mood = .happy; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.state.mood == .happy { self?.state.mood = .idle } } }
        case .owlThinking:
            if state.mood == .idle { state.mood = .thinking }
        case .owlIdle:
            if state.mood == .thinking { state.mood = .idle }
        }
    }
}

struct BuddyView: View {
    @ObservedObject var state: BuddyState
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let b = state.bubble {
                Text(b).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white).shadow(color: .black.opacity(0.18), radius: 4, y: 1))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 140)
                    .transition(.scale.combined(with: .opacity))
            }
            KiriCharacter(mood: state.mood, leaves: 2, style: state.style)
                .frame(width: 230, height: 300)
                .scaleEffect(0.5)
                .frame(width: 120, height: 150)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .help("Your test buddy · click to run tests")
        }
        .frame(width: BuddyController.size.width, height: BuddyController.size.height, alignment: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.bubble)
    }
}
