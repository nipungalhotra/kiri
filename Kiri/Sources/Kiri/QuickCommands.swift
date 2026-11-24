import AppKit
import ApplicationServices

/// Everyday Mac commands Hoot does instantly, on the Mac itself, without asking Claude:
///   "volume up" · "set volume to 30" · "mute" · "minimise this" · "minimise the Safari window"
///   "full screen" · "move this to the left" · "pause" · "next song" · "set a timer for 5 minutes"
///   "what time is it" · "what's the date" · "battery" · "open Notes"
enum QuickCommand: Equatable {
    enum Media: String { case play, pause, toggle, next, previous }
    enum Side: String { case left, right, center, maximize }
    case volumeStep(Int), volume(Int), mute(Bool)
    case minimize(app: String?), fullScreen, snap(Side), hideOthers
    case media(Media)
    case timer(seconds: Int)
    case time, date, battery
    case openApp(String)
    case joinMeeting

    /// "please can you minimise this for me" → "minimise this"
    static func normalize(_ text: String) -> String {
        var t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,").union(.whitespacesAndNewlines))
        for p in ["hey hoot ", "hoot ", "please ", "can you ", "could you ", "would you ", "can you please ", "just "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
        }
        for s in [" please", " for me", " now", " hoot"] where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        return t.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ text: String) -> QuickCommand? {
        let t = normalize(text)
        guard !t.isEmpty, t.count < 60 else { return nil }
        func m(_ p: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "^" + p + "$"),
                  let r = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<r.numberOfRanges).map { i in Range(r.range(at: i), in: t).map { String(t[$0]) } ?? "" }
        }
        // volume
        if m(#"(?:turn (?:the )?volume up|volume up|louder|turn it up|make it louder|increase (?:the )?volume)"#) != nil { return .volumeStep(15) }
        if m(#"(?:turn (?:the )?volume down|volume down|quieter|softer|turn it down|make it quieter|lower (?:the )?volume|decrease (?:the )?volume)"#) != nil { return .volumeStep(-15) }
        if let g = m(#"(?:set (?:the )?)?volume (?:to |at )?(\d{1,3})(?: ?%| percent)?"#), let n = Int(g[1]) { return .volume(min(100, n)) }
        if m(#"(?:mute|mute (?:the )?(?:sound|volume|audio)|silence)"#) != nil { return .mute(true) }
        if m(#"(?:unmute|unmute (?:the )?(?:sound|volume|audio))"#) != nil { return .mute(false) }
        // windows
        if m(#"(?:minimi[sz]e|hide)(?: (?:this|it|the window|this window|that))?(?: window)?"#) != nil { return .minimize(app: nil) }
        if let g = m(#"(?:minimi[sz]e|hide) (?:the |my )?([a-z0-9 .]{2,30}?)(?: window| windows| app)?"#),
           !["everything", "all", "other apps", "others", "everything else"].contains(g[1]) { return .minimize(app: g[1]) }
        if m(#"(?:hide (?:everything else|other apps|the others|others)|clean up my screen|focus on this window)"#) != nil { return .hideOthers }
        if m(#"(?:make (?:this|it|the window) )?full ?screen(?: (?:this|it|mode))?|(?:exit|leave) full ?screen"#) != nil { return .fullScreen }
        if let g = m(#"(?:move|put|snap|send) (?:this|it|the window|this window) (?:to )?(?:the )?(left|right)(?: half| side)?(?: of the screen)?"#) {
            return .snap(g[1] == "left" ? .left : .right)
        }
        if m(#"(?:center|centre) (?:this|it|the window|this window)"#) != nil { return .snap(.center) }
        if m(#"(?:maximi[sz]e|make (?:this|it) bigger|fill the screen)(?: (?:this|it|the window))?"#) != nil { return .snap(.maximize) }
        // media
        if m(#"(?:play|resume|play music|resume music|play the music|start the music|keep playing)"#) != nil { return .media(.play) }
        if m(#"(?:pause|pause music|pause the music|stop the music|stop music|pause it)"#) != nil { return .media(.pause) }
        if m(#"(?:next|next song|next track|skip|skip (?:this|it|this song|the song)|play the next song)"#) != nil { return .media(.next) }
        if m(#"(?:previous|previous song|previous track|last song|go back a song|play the previous song)"#) != nil { return .media(.previous) }
        // timer
        if let g = m(#"(?:set |start )?(?:a |an )?(\d{1,3}|a|an|one|two|three|five|ten|fifteen|twenty|thirty) ?(seconds?|secs?|minutes?|mins?|hours?) timer"#)
            ?? m(#"(?:set |start )?(?:a |an )?timer (?:for |of )?(\d{1,3}|a|an|one|two|three|five|ten|fifteen|twenty|thirty) ?(seconds?|secs?|minutes?|mins?|hours?)"#) {
            let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30]
            let n = Int(g[1]) ?? words[g[1]] ?? 1
            let unit = g[2].hasPrefix("h") ? 3600 : (g[2].hasPrefix("s") ? 1 : 60)
            return n > 0 ? .timer(seconds: n * unit) : nil
        }
        if m(#"(?:join|open|start) (?:the |my )?(?:meeting|call|zoom|meet|teams call)(?: link)?|join"#) != nil { return .joinMeeting }
        // little facts
        if m(#"(?:what time is it|what's the time|what is the time|time|tell me the time|current time)"#) != nil { return .time }
        if m(#"(?:what's the date|what is the date|what day is it|what's today's date|today's date|date|what's today)"#) != nil { return .date }
        if m(#"(?:battery|how much battery|how much battery (?:do i have|is left)|what's my battery|battery level|how's my battery)"#) != nil { return .battery }
        // open an installed app (only if one really has that name)
        if let g = m(#"(?:open|launch|start|switch to|go to) (?:the )?([a-z0-9 .+-]{2,30}?)(?: app)?"#), QuickCommands.appURL(named: g[1]) != nil {
            return .openApp(g[1])
        }
        return nil
    }
}

@MainActor
enum QuickCommands {
    /// The last app you used that isn't Kiri (what "this window" means while you talk to Hoot).
    private(set) static var lastOtherApp: NSRunningApplication?
    private static var observer: Any?
    /// Timers end by calling this (Hoot announces it).
    static var onTimerDone: ((String) -> Void)?

    static func startTracking() {
        guard observer == nil else { return }
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { lastOtherApp = f }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { lastOtherApp = app }
        }
    }

    /// Does it; returns a short line for the bubble / voice.
    static func run(_ c: QuickCommand) async -> String {
        switch c {
        case .volumeStep(let d):
            let now = Int(osascript("output volume of (get volume settings)") ?? "") ?? 50
            let v = max(0, min(100, now + d))
            _ = osascript("set volume output volume \(v)")
            return "🔊 Volume \(v)%"
        case .volume(let v):
            _ = osascript("set volume output volume \(v)")
            return "🔊 Volume \(v)%"
        case .mute(let on):
            _ = osascript(on ? "set volume with output muted" : "set volume without output muted")
            return on ? "🔇 Muted" : "🔊 Sound back on"
        case .minimize(let name):
            return windowAction { app, win in
                if let name {
                    guard let target = runningApp(named: name) else { return "I couldn't find an open app called “\(name)”." }
                    let ax = AXUIElementCreateApplication(target.processIdentifier)
                    let wins = (copy(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                    guard !wins.isEmpty else { target.hide(); return "Hid \(target.localizedName ?? name)." }
                    for w in wins { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
                    return "🪟 Minimised \(target.localizedName ?? name)"
                }
                guard let win else { return "There's no window to minimise." }
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                return "🪟 Minimised \(app.localizedName ?? "the window")"
            }
        case .fullScreen:
            return windowAction { app, win in
                guard let win else { return "There's no window to make full screen." }
                let on = (copy(win, "AXFullScreen") as? Bool) ?? false
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (!on) as CFBoolean)
                return on ? "🪟 Left full screen" : "🪟 \(app.localizedName ?? "Window") is full screen"
            }
        case .snap(let side):
            return windowAction { app, win in
                guard let win, let screen = NSScreen.main else { return "There's no window to move." }
                let f = screen.visibleFrame
                let primaryH = NSScreen.screens.first?.frame.height ?? f.height
                var r = f
                switch side {
                case .left: r.size.width = f.width / 2
                case .right: r.size.width = f.width / 2; r.origin.x = f.midX
                case .maximize: break
                case .center: r = f.insetBy(dx: f.width * 0.15, dy: f.height * 0.1)
                }
                var pos = CGPoint(x: r.minX, y: primaryH - r.maxY)       // accessibility uses top-left coordinates
                var size = CGSize(width: r.width, height: r.height)
                if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
                if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) }
                let what = ["left": "to the left", "right": "to the right", "center": "to the middle", "maximize": "to fill the screen"][side.rawValue] ?? ""
                return "🪟 Moved \(app.localizedName ?? "the window") \(what)"
            }
        case .hideOthers:
            let keep = lastOtherApp?.processIdentifier
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular
                && a.processIdentifier != keep && a.processIdentifier != getpid() { a.hide() }
            return "🧹 Hid everything else"
        case .media(let what):
            return media(what)
        case .timer(let secs):
            let label = secs >= 3600 ? "\(secs / 3600) hour\(secs >= 7200 ? "s" : "")"
                : secs >= 60 ? "\(secs / 60) minute\(secs >= 120 ? "s" : "")" : "\(secs) second\(secs == 1 ? "" : "s")"
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs)) {
                NSSound(named: "Glass")?.play()
                onTimerDone?(label)
            }
            return "⏲ Timer set for \(label)"
        case .time:
            return "🕐 It's \(Date().formatted(date: .omitted, time: .shortened))"
        case .date:
            return "📅 Today is \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))"
        case .battery:
            guard let b = Battery.read() else { return "This Mac doesn't have a battery." }
            return "🔋 Battery \(b.percent)%" + (b.onBattery ? "" : ", charging")
        case .joinMeeting:
            guard let link = MeetingWatcher.lastLink ?? MeetingWatcher.currentLink() else { return "I don't see a video link for a meeting right now." }
            NSWorkspace.shared.open(link)
            return "🎥 Joining your meeting"
        case .openApp(let name):
            guard let url = appURL(named: name) else { return "I couldn't find an app called “\(name)”." }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return "🚀 Opened \(url.deletingPathExtension().lastPathComponent)"
        }
    }

    // MARK: Helpers

    /// Window moves need Accessibility permission (System Settings → Privacy & Security → Accessibility).
    static var canControlWindows: Bool { AXIsProcessTrusted() }

    private static func windowAction(_ body: (NSRunningApplication, AXUIElement?) -> String) -> String {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            return "To move windows I need Accessibility: System Settings → Privacy & Security → Accessibility → turn on Kiri, then ask again."
        }
        guard let app = lastOtherApp ?? NSWorkspace.shared.frontmostApplication else { return "There's no window to work with." }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let win = copy(ax, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            ?? (copy(ax, kAXWindowsAttribute) as? [AXUIElement])?.first
        return body(app, win)
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func runningApp(named name: String) -> NSRunningApplication? {
        let n = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        return apps.first { ($0.localizedName ?? "").lowercased() == n }
            ?? apps.first { ($0.localizedName ?? "").lowercased().hasPrefix(n) }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(n) }
    }

    /// An installed app whose name matches (e.g. "notes", "vs code", "chrome").
    nonisolated static func appURL(named raw: String) -> URL? {
        let aliases = ["vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code", "chrome": "Google Chrome",
                       "settings": "System Settings", "system preferences": "System Settings", "app store": "App Store", "facetime": "FaceTime"]
        let name = aliases[raw.lowercased()] ?? raw
        let ws = NSWorkspace.shared
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == name.lowercased() + ".app" }) { return URL(fileURLWithPath: dir).appendingPathComponent(hit) }
        }
        if let id = ["safari": "com.apple.Safari", "finder": "com.apple.finder"][name.lowercased()] { return ws.urlForApplication(withBundleIdentifier: id) }
        return nil
    }

    private static func media(_ what: QuickCommand.Media) -> String {
        let running = { (id: String) in !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
        let player = running("com.spotify.client") ? "Spotify" : "Music"
        let verb: String
        switch what {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        if player == "Music", !running("com.apple.Music"), what != .play { return "Nothing is playing." }
        guard osascript("tell application \"\(player)\" to \(verb)") != nil else {
            return "I couldn't control \(player). If macOS asked, allow Kiri to control it and try again."
        }
        switch what {
        case .play: return "▶️ Playing (\(player))"
        case .pause: return "⏸ Paused"
        case .toggle: return "⏯ Done"
        case .next: return "⏭ Next song"
        case .previous: return "⏮ Previous song"
        }
    }

    /// Runs a tiny AppleScript; returns its output, or nil if it failed.
    @discardableResult
    static func osascript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
