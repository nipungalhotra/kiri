import AppKit
import SwiftUI

/// Kiri runs in the background, so its windows are almost never in the active app. By default
/// macOS swallows the first click on such a window ("activate me"), so clicks on the pet did
/// nothing. Accepting the first mouse makes every click count.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless, transparent panel that floats above other windows on every Space.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetWindowController {
    static let compact = NSSize(width: 230, height: 380)
    static let expanded = NSSize(width: 400, height: 810)

    let state: PetState
    let panel: PetPanel
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragMoved = false

    init(state: PetState) {
        self.state = state
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: Self.compact),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = ClickThroughHostingView(rootView: RootView(state: state, controller: self))
        host.frame = NSRect(origin: .zero, size: Self.compact)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        state.onChatToggle = { [weak self] open in self?.setExpanded(open) }

        if let vis = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vis.maxX - Self.compact.width - 20, y: vis.minY + 10))
        }
        PetGeometry.frame = panel.frame
        RenderGate.shared.watch(panel)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let f = self?.panel.frame { PetGeometry.frame = f } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let f = self?.panel.frame { PetGeometry.frame = f } }
        }
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFrontRegardless(); RenderGate.shared.refresh() }
    func hide() { panel.orderOut(nil); RenderGate.shared.refresh() }
    func toggle() { isVisible ? hide() : show() }

    /// Grow/shrink while keeping Kiri (the bottom-right corner) where it is.
    func setExpanded(_ on: Bool) {
        let size = on ? Self.expanded : Self.compact
        let f = panel.frame
        var nf = NSRect(x: f.maxX - size.width, y: f.minY, width: size.width, height: size.height)
        if let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if nf.maxY > vis.maxY { nf.origin.y = vis.maxY - nf.height }
            if nf.minX < vis.minX { nf.origin.x = vis.minX }
        }
        panel.setFrame(nf, display: true)
        if on {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // Drag by following the real mouse position: window coordinates shift while moving,
    // so SwiftUI's own translation would jitter.
    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            Log.write("mouse down on pet")
            dragStart = (mouse, panel.frame.origin)
            dragMoved = false
        }
        guard let start = dragStart else { return }
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if abs(dx) + abs(dy) > 3 { dragMoved = true }
        if dragMoved { panel.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy)) }
    }

    /// Returns true if this was a drag (not a click).
    func dragEnded() -> Bool {
        defer { dragStart = nil }
        return dragMoved
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetWindowController!
    private var statusItem: NSStatusItem!
    private var state: PetState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = PetState()
        controller = PetWindowController(state: state)
        if CommandLine.arguments.contains("--notch") { UserDefaults.standard.set(DisplayMode.notch.rawValue, forKey: "displayMode") }
        if CommandLine.arguments.contains("--desktop") { UserDefaults.standard.set(DisplayMode.desktop.rawValue, forKey: "displayMode") }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🦉"
        statusItem.button?.toolTip = "Kiri"
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        add("Show / Hide Kiri", #selector(toggleKiri))
        add("Open Chat  (⌥Space)", #selector(openChat))
        add("Run Tests", #selector(runTests))
        add("Choose Project…", #selector(chooseProject))
        add("What's on My Screen?", #selector(askScreen))
        add("Set Up Terminal Watching…", #selector(terminalSetup))
        menu.addItem(.separator())
        let displayItem = menu.addItem(withTitle: "Display", action: nil, keyEquivalent: "")
        displayMenu.autoenablesItems = false
        displayItem.submenu = displayMenu
        menu.addItem(.separator())
        add("Quit Kiri", #selector(quit), "q")
        statusItem.menu = menu

        applyDisplayMode()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDisplayMode() }
        }
        hotKey = GlobalHotKey()
        GlobalHotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        state.greet()
    }

    // MARK: Hotkey

    private var hotKey: GlobalHotKey?

    /// ⌥Space: open the chat with the text box focused (ready for Wispr Flow), or close it.
    private func hotKeyPressed() {
        Log.write("hotkey pressed (chatOpen was \(state.chatOpen))")
        if let n = notchController { n.show() } else { controller.show() }
        if state.chatOpen {
            state.chatOpen = false
        } else {
            NSApp.activate(ignoringOtherApps: true)
            state.chatOpen = true
        }
    }

    // MARK: Notch vs desktop

    private var notchController: NotchController?
    private let displayMenu = NSMenu()

    private var displayMode: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .auto
    }

    /// Notch Macs get the notch island; other Macs get the desktop pet (unless the user picks otherwise).
    private func applyDisplayMode() {
        let mode = displayMode
        let notch: NotchInfo? = switch mode {
        case .desktop: nil
        case .auto: NotchInfo.real()
        case .notch: NotchInfo.real() ?? NotchInfo.simulated()
        }
        if let notch {
            if notchController == nil || notchController?.notch.screen != notch.screen || notchController?.notch.width != notch.width {
                notchController?.hide()
                notchController = NotchController(state: state, notch: notch)
            }
            state.onChatToggle = nil
            controller.hide()
            notchController?.show()
        } else {
            notchController?.hide()
            notchController = nil
            state.onChatToggle = { [weak self] open in self?.controller.setExpanded(open) }
            controller.show()
        }

        displayMenu.removeAllItems()
        let hasNotch = NotchInfo.real() != nil
        for m in DisplayMode.allCases {
            let item = displayMenu.addItem(withTitle: m.title, action: #selector(pickDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = m == mode ? .on : .off
        }
        displayMenu.addItem(.separator())
        let info = displayMenu.addItem(withTitle: hasNotch ? "This Mac has a notch" : "This Mac has no notch", action: nil, keyEquivalent: "")
        info.isEnabled = false
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "displayMode")
        state.chatOpen = false
        applyDisplayMode()
    }

    @objc private func toggleKiri() {
        if let n = notchController { n.panel.isVisible ? n.hide() : n.show() } else { controller.toggle() }
    }
    @objc private func openChat() {
        if let n = notchController { n.show() } else { controller.show() }
        state.chatOpen = true
    }
    @objc private func runTests() {
        if let n = notchController { n.show() } else { controller.show() }
        state.runTests()
    }
    @objc private func chooseProject() { state.chooseProject() }
    @objc private func askScreen() { if let n = notchController { n.show() } else { controller.show() }; state.askAboutScreen() }
    @objc private func terminalSetup() { state.setUpTerminalWatching() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum KiriApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if args.contains("--selftest") { SelfTest.run(); return }
        if let i = args.firstIndex(of: "--gif"), i + 1 < args.count {
            GifExport.render(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = args.firstIndex(of: "--notch-sheet"), i + 1 < args.count {
            NotchSheet.render(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = args.firstIndex(of: "--concepts"), i + 1 < args.count {
            ConceptSheet.render(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// `Kiri --snapshot out.png` renders every mood to an image (handy for checking art and for sharing).
enum Snapshot {
    @MainActor
    static func render(to url: URL) {
        let sheet = VStack(spacing: 14) {
            Text("Kiri — moods").font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
            HStack(spacing: 10) {
                ForEach(Mood.allCases, id: \.self) { mood in
                    VStack(spacing: 4) {
                        KiriFrame(mood: mood, leaves: mood == .happy ? 3 : 1, t: 1.37)
                        Text(mood.rawValue).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SpeechBubble(text: "Tests failed 😢 Want me to fix it?")
        }
        .padding(24)
        .background(Color(red: 0.96, green: 0.97, blue: 0.98))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot failed"); return
        }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
