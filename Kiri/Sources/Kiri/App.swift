import AVFoundation
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        add("Commit My Changes…", #selector(commit))
        add("Daily Brief", #selector(brief))
        add("Explain What I Copied", #selector(explainClipboard))
        add("Hoot's Achievements", #selector(achievements))
        let cmdItem = menu.addItem(withTitle: "My Commands", action: nil, keyEquivalent: "")
        cmdItem.submenu = commandsMenu
        commandsMenu.delegate = self
        menu.addItem(.separator())
        add("Set Up Terminal Watching…", #selector(terminalSetup))
        add("Setup Check…", #selector(showSetup))
        updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdatesClicked), keyEquivalent: "")
        updateItem?.target = self
        menu.addItem(.separator())
        let optItem = menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")
        optItem.submenu = optionsMenu
        optionsMenu.delegate = self
        let buddyItem = menu.addItem(withTitle: "Buddy Pet", action: nil, keyEquivalent: "")
        buddyItem.submenu = buddyMenu
        buddyMenu.delegate = self
        let voiceItem = menu.addItem(withTitle: "Voice", action: nil, keyEquivalent: "")
        voiceItem.submenu = voiceMenu
        voiceMenu.delegate = self
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
        state.onBuddyEvent = { [weak self] e in self?.buddy?.react(e) }
        applyBuddy()
        state.greet()
        setup.showIfNeeded(state: state)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkUpdates(quietly: true) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpdates(quietly: true) }
        }
    }

    // MARK: Setup, updates, buddy, extra menus

    private let setup = SetupWindow()
    private var updateItem: NSMenuItem?
    private let commandsMenu = NSMenu()
    private let optionsMenu = NSMenu()
    private let buddyMenu = NSMenu()
    private var buddy: BuddyController?

    @objc private func showSetup() { setup.show(state: state) }
    @objc private func commit() { showPet(); state.chatOpen = true; state.commitChanges() }
    @objc private func brief() { showPet(); state.dailyBrief() }
    @objc private func explainClipboard() { showPet(); state.explainClipboard() }
    @objc private func achievements() { showPet(); state.showAchievements() }
    private func showPet() { if let n = notchController { n.show() } else { controller.show() } }

    @objc private func checkUpdatesClicked() { checkUpdates(quietly: false) }
    private func checkUpdates(quietly: Bool) {
        if let a = Updates.available, !quietly { NSWorkspace.shared.open(a.url); return }
        let found: @MainActor (String, URL) -> Void = { [weak self] version, url in
            guard let self else { return }
            self.updateItem?.title = "Update to Kiri \(version)…"
            if !self.state.quiet { self.state.say("Kiri \(version) is out! 🦉 → Update to get it ✨", for: 10) }
            if !quietly { NSWorkspace.shared.open(url) }
        }
        let latest: @MainActor () -> Void = { [weak self] in
            self?.state.say("You have the latest Kiri (\(Updates.current)) ✅", for: 4)
        }
        Updates.check(force: !quietly, found: found, upToDate: quietly ? nil : latest)
    }

    private var buddyStyle: CharacterStyle? {
        UserDefaults.standard.string(forKey: "buddyStyle").flatMap(CharacterStyle.init(rawValue:))
    }

    /// The buddy only lives next to the desktop owl (not in the notch).
    private func applyBuddy() {
        buddy?.close()
        buddy = nil
        guard let style = buddyStyle, notchController == nil, controller.isVisible else { return }
        buddy = BuddyController(style: style, owlPanel: controller.panel, pet: state)
    }

    @objc private func pickBuddy(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "buddyStyle")
        applyBuddy()
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let c = CustomCommands.all().first(where: { $0.name == name }) else { return }
        showPet()
        state.chatOpen = true
        state.note("▶︎ \(name)")
        state.runCustom(c)
    }
    @objc private func openCommandsFolder() {
        CustomCommands.prepareFolder()
        NSWorkspace.shared.open(CustomCommands.folder)
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        switch key {
        case "quiet": state.quiet.toggle()
        case "showAccessories": Evolution.shared.showAccessories.toggle()
        default:
            let d = UserDefaults.standard
            d.set(!(d.object(forKey: key) as? Bool ?? true), forKey: key)
        }
    }
    @objc private func forgetMemory() {
        guard let p = state.projectURL else { return }
        guard Approval.ask("Forget \(p.lastPathComponent)?", "Kiri will delete its notes about what you worked on in this project. Your files aren't touched.", allow: "Forget") else { return }
        ProjectMemory.forget(p)
        state.say("Forgotten 🧹", for: 3)
    }

    private func buildExtraMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, _ obj: Any? = nil, on: Bool? = nil) {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = obj
            if let on { i.state = on ? .on : .off }
            if action == nil { i.isEnabled = false }
        }
        let d = UserDefaults.standard
        if menu === commandsMenu {
            CustomCommands.refreshShortcuts()
            let all = CustomCommands.all()
            if all.isEmpty { item("No commands yet", nil) }
            for c in all { item("“\(c.name)”", #selector(runCommand(_:)), c.name) }
            menu.addItem(.separator())
            item("Open Commands Folder…", #selector(openCommandsFolder))
        } else if menu === optionsMenu {
            item("Quiet Mode (Focus)", #selector(toggleOption(_:)), "quiet", on: state.quiet)
            item("Break Reminders", #selector(toggleOption(_:)), "breakReminders", on: FocusCoach.enabled)
            item("Remember My Work", #selector(toggleOption(_:)), "rememberWork", on: ProjectMemory.enabled)
            item("Offer Help When I Copy an Error", #selector(toggleOption(_:)), "watchClipboard",
                 on: (d.object(forKey: "watchClipboard") as? Bool ?? true) && ClipboardWatcher.autoAllowed)
            item("Show Hoot's Accessories", #selector(toggleOption(_:)), "showAccessories", on: Evolution.shared.showAccessories)
            menu.addItem(.separator())
            item("Forget This Project's Memory…", state.projectURL == nil ? nil : #selector(forgetMemory))
        } else if menu === buddyMenu {
            item("Off", #selector(pickBuddy(_:)), nil, on: buddyStyle == nil)
            for s in BuddyController.styles { item(s.title, #selector(pickBuddy(_:)), s.rawValue, on: buddyStyle == s) }
            if notchController != nil { menu.addItem(.separator()); item("Shows in desktop mode only", nil) }
        }
    }

    // MARK: Voice menu (rebuilt each time it opens)

    private let voiceMenu = NSMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === commandsMenu || menu === optionsMenu || menu === buddyMenu { buildExtraMenu(menu); return }
        guard menu === voiceMenu else { return }
        menu.removeAllItems()
        let listen = menu.addItem(withTitle: "Listen when I press ⌥Space", action: #selector(toggleListen), keyEquivalent: "")
        listen.target = self
        listen.state = state.listenOnHotkey ? .on : .off
        let hey = menu.addItem(withTitle: "Listen for “Hey Hoot”", action: #selector(toggleHeyHoot), keyEquivalent: "")
        hey.target = self
        hey.state = state.heyHoot ? .on : .off
        let test = menu.addItem(withTitle: "Test “Hey Hoot”…", action: #selector(testWake), keyEquivalent: "")
        test.target = self
        menu.addItem(.separator())
        let header = menu.addItem(withTitle: "Hoot's voice", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let current = Voice.chosenVoice?.identifier
        for v in Voice.femaleVoices {
            let q = v.quality == .premium ? " (premium)" : (v.quality == .enhanced ? " (enhanced)" : "")
            let item = menu.addItem(withTitle: "\(v.name) — \(v.language)\(q)", action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.identifier
            item.state = v.identifier == current ? .on : .off
        }
        menu.addItem(.separator())
        let more = menu.addItem(withTitle: "Get nicer voices…", action: #selector(openVoiceSettings), keyEquivalent: "")
        more.target = self
    }

    @objc private func toggleListen() { state.listenOnHotkey.toggle() }
    @objc private func toggleHeyHoot() { state.heyHoot.toggle() }
    @objc private func testWake() { showPet(); state.testWakeWord() }
    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let v = AVSpeechSynthesisVoice(identifier: id) else { return }
        Voice.choose(v)
    }
    @objc private func openVoiceSettings() {
        // Accessibility → Spoken Content, where Premium/Enhanced voices (e.g. Ava, Zoe, Isha) can be downloaded.
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") { NSWorkspace.shared.open(u) }
    }

    // MARK: Hotkey

    private var hotKey: GlobalHotKey?

    /// ⌥Space: open the chat with the text box focused (ready for Wispr Flow), or close it.
    private func hotKeyPressed() {
        Log.write("hotkey pressed (chatOpen was \(state.chatOpen))")
        if let n = notchController { n.show() } else { controller.show() }
        if VoiceInput.shared.listening {
            VoiceInput.shared.finish(send: true)      // pressed again while listening: send now
        } else if state.listenOnHotkey {
            NSApp.activate(ignoringOtherApps: true)
            state.chatOpen = true
            state.listen()                            // always listen, even if the chat is already open
        } else {
            NSApp.activate(ignoringOtherApps: true)
            state.chatOpen.toggle()
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
            buddy?.close(); buddy = nil
        } else {
            notchController?.hide()
            notchController = nil
            state.onChatToggle = { [weak self] open in self?.controller.setExpanded(open) }
            controller.show()
            if buddy == nil, setupDone { applyBuddy() }
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
        if let n = notchController { n.panel.isVisible ? n.hide() : n.show() } else { controller.toggle(); applyBuddy() }
    }
    private var setupDone: Bool { state != nil && controller != nil }
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
        if let i = args.firstIndex(of: "--owl-shot"), i + 1 < args.count {
            // Hoot with every accessory (+ focus badge) for checking the art: Kiri --owl-shot out.png --accessories
            PetSignals.shared.quiet = args.contains("--quiet")
            PetSignals.shared.busySince = Date().addingTimeInterval(-42)
            PetSignals.shared.activity = "Editing calculator.py"
            let view = HStack(spacing: 0) {
                OwlFrame(mood: .idle, t: 1.0, followMouse: false, lookOverride: .zero)
                OwlFrame(mood: .working, t: 3.3, followMouse: false)
                OwlFrame(mood: .working, t: 13.4, followMouse: false)
                OwlFrame(mood: .thinking, t: 2.1, followMouse: false)
            }.padding(10).background(Color(white: 0.92))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if let i = args.firstIndex(of: "--chat-shot"), i + 1 < args.count {
            // Renders the chat window with sample messages: Kiri --chat-shot out.png [--dark]
            let state = PetState()
            state.messages = [
                ChatMessage(role: .user, text: "Can you change my wallpaper?"),
                ChatMessage(role: .kiri, text: "Sure! Pick one:\n- **One of your own photos:** tell me the file path, like `~/Pictures/beach.jpg`.\n- **A built-in macOS wallpaper:** I can list them so you can pick."),
                ChatMessage(role: .user, text: "Cute, can you minimise the Claude window?"),
                ChatMessage(role: .kiri, text: "Done! I minimised it 🦉"),
                ChatMessage(role: .note, text: "🦉 Minimised Claude"),
            ]
            let host = NSHostingView(rootView: ChatView(state: state).frame(width: 400, height: 600))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
            win.backgroundColor = args.contains("--dark") ? .black : .white
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        Log.prepare()
        if let i = args.firstIndex(of: "--wake-probe"), i + 1 < args.count {
            WakeProbe.run(args[i + 1])
            RunLoop.main.run()
            return
        }
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
