import AVFoundation
import AppKit
import EventKit
import ScreenCaptureKit
import Speech
import SwiftUI

/// First-launch checklist: is Claude installed and signed in, which permissions are on, and a
/// one-click fix for each thing that isn't. Also under 🦉 → Setup Check….
@MainActor
final class SetupCheck: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let ok: Bool
        /// Nice to have; Kiri works without it.
        let optional: Bool
        var fixTitle: String? = nil
        var fix: (() -> Void)? = nil
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var checking = false
    weak var state: PetState?

    var requiredMissing: Int { items.filter { !$0.ok && !$0.optional }.count }

    func refresh() {
        checking = true
        Task { @MainActor in
            let claude = ClaudeRunner.claudePath
            let signedIn = await Task.detached { Self.claudeSignedIn() }.value
            let gh = await Task.detached { Self.githubReady() }.value
            let screen = await Self.screenAllowed()
            var list: [Item] = []

            list.append(Item(id: "claude", title: "Claude Code installed",
                             detail: claude.map { "Found at \($0)" } ?? "Kiri's brain. Install it with: npm install -g @anthropic-ai/claude-code",
                             ok: claude != nil, optional: false,
                             fixTitle: "How to install", fix: { NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!) }))
            list.append(Item(id: "login", title: "Signed in to Claude",
                             detail: signedIn ? "Ready to chat." : "Opens Terminal: type /login and sign in, then come back.",
                             ok: signedIn, optional: false,
                             fixTitle: "Sign in…", fix: { Self.openTerminal(running: "claude --setting-sources project,local") }))
            let apps = Bundle.main.bundlePath.hasPrefix("/Applications/")
            list.append(Item(id: "apps", title: "Kiri is in Applications",
                             detail: apps ? "Good: permissions stick." : "Screen help only works when Kiri is in /Applications. Drag it there and reopen.",
                             ok: apps, optional: false))
            let project = state?.projectURL
            list.append(Item(id: "project", title: "Project folder chosen",
                             detail: project.map { "Working in \($0.lastPathComponent)" } ?? "Pick the code folder Hoot should help with.",
                             ok: project != nil, optional: false,
                             fixTitle: "Choose…", fix: { [weak self] in self?.state?.chooseProject(); self?.refresh() }))

            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            list.append(Item(id: "mic", title: "Microphone", detail: "For ⌥Space and “Hey Hoot” voice commands.",
                             ok: mic == .authorized, optional: true,
                             fixTitle: mic == .notDetermined ? "Allow…" : "Open Settings",
                             fix: { [weak self] in
                                 if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self?.refresh() } } }
                                 else { Self.openPrivacy("Privacy_Microphone") }
                             }))
            let speech = SFSpeechRecognizer.authorizationStatus()
            list.append(Item(id: "speech", title: "Speech Recognition", detail: "Turns your voice into text, on your Mac.",
                             ok: speech == .authorized, optional: true,
                             fixTitle: speech == .notDetermined ? "Allow…" : "Open Settings",
                             fix: { [weak self] in
                                 if speech == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self?.refresh() } } }
                                 else { Self.openPrivacy("Privacy_SpeechRecognition") }
                             }))
            list.append(Item(id: "screen", title: "Screen Recording", detail: "For “what's on my screen?” and pointing at buttons.",
                             ok: screen, optional: true,
                             fixTitle: "Open Settings", fix: { ScreenHelp.requestPermission(); Self.openPrivacy("Privacy_ScreenCapture") }))
            let rem = EKEventStore.authorizationStatus(for: .reminder)
            list.append(Item(id: "reminders", title: "Reminders", detail: "So “remind me to…” works and the daily brief can list what's due.",
                             ok: rem == .fullAccess, optional: true,
                             fixTitle: rem == .notDetermined ? "Allow…" : "Open Settings",
                             fix: { [weak self] in
                                 if rem == .notDetermined { Task { _ = try? await EKEventStore().requestFullAccessToReminders(); self?.refresh() } }
                                 else { Self.openPrivacy("Privacy_Reminders") }
                             }))
            let cal = EKEventStore.authorizationStatus(for: .event)
            list.append(Item(id: "calendar", title: "Calendar", detail: "So the daily brief can tell you today's meetings.",
                             ok: cal == .fullAccess, optional: true,
                             fixTitle: cal == .notDetermined ? "Allow…" : "Open Settings",
                             fix: { [weak self] in
                                 if cal == .notDetermined { Task { _ = try? await EKEventStore().requestFullAccessToEvents(); self?.refresh() } }
                                 else { Self.openPrivacy("Privacy_Calendars") }
                             }))
            list.append(Item(id: "gh", title: "GitHub CLI signed in", detail: gh ? "PR buddy can watch your pull requests." : "Optional, for the PR buddy: install `gh` (brew install gh) and run gh auth login.",
                             ok: gh, optional: true,
                             fixTitle: gh ? nil : "Sign in…", fix: gh ? nil : { Self.openTerminal(running: "gh auth login") }))
            list.append(Item(id: "terminal", title: "Terminal watching", detail: "Hoot notices failed commands and offers help.",
                             ok: TerminalWatcher.isInstalled, optional: true,
                             fixTitle: "Set up…", fix: { [weak self] in self?.state?.setUpTerminalWatching(); self?.refresh() }))
            let clip = ClipboardWatcher.autoAllowed
            list.append(Item(id: "clipboard", title: "Clipboard error help", detail: clip
                             ? "Hoot offers help when you copy an error."
                             : "Use 🦉 → Explain What I Copied. For automatic offers: System Settings → Privacy & Security → Paste from Other Apps → Kiri → Allow.",
                             ok: clip, optional: true,
                             fixTitle: clip ? nil : "Open Settings", fix: clip ? nil : { Self.openPrivacy("Privacy_Pasteboard") }))
            items = list
            checking = false
            Log.write("setup check: \(list.filter { $0.ok }.count)/\(list.count) ok, required missing \(requiredMissing)")
        }
    }

    // MARK: probes

    /// Claude Code keeps its login in the Keychain (or a credentials file on some setups); an API key also works.
    nonisolated static func claudeSignedIn() -> Bool {
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil { return true }
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
        if FileManager.default.fileExists(atPath: file.path) { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]   // no -w: never reads the secret
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    nonisolated static func githubReady() -> Bool {
        GitHub.run(["auth", "status"], in: URL(fileURLWithPath: NSHomeDirectory())).code == 0
    }

    static func screenAllowed() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // the preflight can say no on recent macOS even when access is on, so ask ScreenCaptureKit
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
    }

    static func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    /// Opens Terminal with a command ready to run (via a small .command file).
    static func openTerminal(running command: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("kiri-setup.command")
        let script = "#!/bin/zsh -l\necho 'Kiri setup: running \(command)'\n\(command)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

struct SetupView: View {
    @ObservedObject var check: SetupCheck
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("🦉").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let's set up Hoot").font(.title2.bold())
                    Text(check.requiredMissing == 0 ? "You're ready! The rest is optional." : "\(check.requiredMissing) thing\(check.requiredMissing == 1 ? "" : "s") left before Hoot can help.")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(check.items) { item in row(item) }
                }
            }
            HStack {
                if check.checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Check again") { check.refresh() }
                Button("Done", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 600)
    }

    private func row(_ item: SetupCheck.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : (item.optional ? "circle.dashed" : "exclamationmark.triangle.fill"))
                .foregroundStyle(item.ok ? .green : (item.optional ? .secondary : .orange))
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title + (item.optional ? "  (optional)" : "")).font(.headline)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !item.ok, let title = item.fixTitle, let fix = item.fix {
                Button(title, action: fix).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

@MainActor
final class SetupWindow {
    private var window: NSWindow?
    let check = SetupCheck()

    func show(state: PetState) {
        check.state = state
        check.refresh()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Kiri Setup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(check: check) { [weak self] in self?.window?.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // re-check when you come back from System Settings or Terminal
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.check.refresh() } }
        }
    }

    /// First launch, or whenever something required is missing (checked quietly).
    func showIfNeeded(state: PetState) {
        let d = UserDefaults.standard
        check.state = state
        if !d.bool(forKey: "setupShownV1") {
            d.set(true, forKey: "setupShownV1")
            show(state: state)
            return
        }
        Task { @MainActor in
            let signedIn = await Task.detached { SetupCheck.claudeSignedIn() }.value
            if ClaudeRunner.claudePath == nil || !signedIn { show(state: state) }
        }
    }
}

// MARK: Updates (checks GitHub releases once a day; nothing personal is sent)

@MainActor
enum Updates {
    static let repo = "nipungalhotra/kiri"
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private(set) static var available: (version: String, url: URL)?

    /// "1.2.10" > "1.2.9"
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func check(force: Bool = false, found: @escaping @MainActor (String, URL) -> Void, upToDate: (@MainActor () -> Void)? = nil) {
        let d = UserDefaults.standard
        if !force, let last = d.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        d.set(Date(), forKey: "lastUpdateCheck")
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kiri-app", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            DispatchQueue.main.async {
                Log.write("update check: latest \(version), running \(current)")
                if isNewer(version, than: current) { available = (version, page); found(version, page) } else { upToDate?() }
            }
        }.resume()
    }
}
