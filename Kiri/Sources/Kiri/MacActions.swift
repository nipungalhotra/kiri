import AppKit
import EventKit

/// Small Mac tasks Claude can ask Kiri to do, via lines like:
///   KIRI_ACTION {"action":"open_app","name":"Safari"}
/// Kiri runs them natively (never as shell commands) and asks first for anything risky.
struct MacAction {
    let kind: String
    let args: [String: Any]

    /// Pull KIRI_ACTION lines out of a reply. Returns the actions and the reply text without them.
    static func extract(from text: String) -> (actions: [MacAction], cleaned: String) {
        var actions: [MacAction] = []
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let r = line.range(of: "KIRI_ACTION") else { kept.append(line); continue }
            let json = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :`"))
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let kind = obj["action"] as? String {
                actions.append(MacAction(kind: kind, args: obj))
            }
        }
        return (actions, kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
enum MacActions {
    /// Runs one action; returns a short line describing what happened.
    static func run(_ a: MacAction) async -> String {
        switch a.kind {
        case "open_app": return openApp(a.args["name"] as? String ?? "")
        case "open_url": return openURL(a.args["url"] as? String ?? "")
        case "reminder": return await addReminder(title: a.args["title"] as? String ?? "Reminder", due: a.args["due"] as? String)
        case "focus": return focus(on: (a.args["on"] as? Bool) ?? true)
        case "organize_folder": return await organize(a.args["folder"] as? String ?? "Downloads")
        default: return "I don't know how to do “\(a.kind)” yet."
        }
    }

    // MARK: Apps & links

    static func openApp(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: ".app", with: "")
        guard !clean.isEmpty, !clean.contains("/") else { return "Which app should I open?" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", clean]
        do { try p.run(); p.waitUntilExit() } catch { return "Couldn't open \(clean)." }
        return p.terminationStatus == 0 ? "Opened \(clean) 🚀" : "I couldn't find an app called “\(clean)”."
    }

    static func openURL(_ s: String) -> String {
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return "That doesn't look like a web link." }
        NSWorkspace.shared.open(u)
        return "Opened \(u.host ?? s) 🌐"
    }

    // MARK: Reminders

    private static let store = EKEventStore()

    static func addReminder(title: String, due: String?) async -> String {
        do {
            guard try await store.requestFullAccessToReminders() else {
                return "I need permission for Reminders: System Settings → Privacy & Security → Reminders → Kiri."
            }
        } catch { return "Reminders access failed: \(error.localizedDescription)" }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        var when = ""
        if let due, let date = parseDate(due) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            r.addAlarm(EKAlarm(absoluteDate: date))
            when = " for " + date.formatted(date: .abbreviated, time: .shortened)
        }
        do { try store.save(r, commit: true) } catch { return "Couldn't save the reminder: \(error.localizedDescription)" }
        return "Reminder added: “\(title)”\(when) ⏰"
    }

    private static func parseDate(_ s: String) -> Date? {
        for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    // MARK: Focus (via the user's Shortcuts — macOS has no public Focus API)

    static let focusOnShortcut = "Kiri Focus On"
    static let focusOffShortcut = "Kiri Focus Off"

    static func focus(on: Bool) -> String {
        let name = on ? focusOnShortcut : focusOffShortcut
        let list = shell("/usr/bin/shortcuts", ["list"])
        guard list.components(separatedBy: "\n").contains(name) else {
            return "To let me toggle Focus, create two shortcuts in the Shortcuts app named “\(focusOnShortcut)” "
                + "(action: Set Focus → Do Not Disturb → On) and “\(focusOffShortcut)” (Turn Off). Then ask again!"
        }
        _ = shell("/usr/bin/shortcuts", ["run", name])
        return on ? "Focus is on. Do Not Disturb 🤫" : "Focus is off 🔔"
    }

    // MARK: Organize a folder (asks first, only moves, never deletes)

    static let categories: [(String, Set<String>)] = [
        ("Images", ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "bmp", "tiff"]),
        ("PDFs", ["pdf"]),
        ("Documents", ["doc", "docx", "txt", "rtf", "md", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv", "numbers"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz"]),
        ("Installers", ["dmg", "pkg", "iso"]),
        ("Videos", ["mov", "mp4", "mkv", "avi", "m4v", "webm"]),
        ("Audio", ["mp3", "wav", "m4a", "aac", "flac"]),
        ("Code", ["swift", "py", "js", "ts", "json", "html", "css", "sh", "java", "c", "cpp", "go", "rs", "ipynb"]),
    ]

    static func organize(_ folderName: String) async -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder: URL = switch folderName.lowercased() {
        case "downloads": home.appendingPathComponent("Downloads")
        case "desktop": home.appendingPathComponent("Desktop")
        case "documents": home.appendingPathComponent("Documents")
        default: URL(fileURLWithPath: (folderName as NSString).expandingTildeInPath)
        }
        guard folder.path.hasPrefix(home.path), folder.path != home.path else {
            return "For safety I only organize folders inside your home folder (like Downloads or Desktop)."
        }
        // Reading the folder can trigger a macOS privacy prompt, so never do it on the main thread.
        let cats = categories
        let planned: [(URL, String)]? = await Task.detached {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                           options: [.skipsHiddenFiles]) else { return nil }
            return items.compactMap { item -> (URL, String)? in
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                let ext = item.pathExtension.lowercased()
                return (item, cats.first { $0.1.contains(ext) }?.0 ?? "Other")
            }
        }.value
        guard let plan = planned else { return "I couldn't read \(folder.lastPathComponent)." }
        guard !plan.isEmpty else { return "\(folder.lastPathComponent) is already tidy ✨" }
        let counts = Dictionary(grouping: plan, by: { $0.1 }).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        guard Approval.ask("Organize \(folder.lastPathComponent)?",
                           "Kiri wants to move \(plan.count) files into folders by type.\n\n\(counts)\n\nNothing is deleted. A list of moves is saved to ~/Library/Logs/Kiri-moves.log.",
                           allow: "Organize") else {
            return "Okay, I left \(folder.lastPathComponent) as it is."
        }
        let (moved, log) = await Task.detached { () -> (Int, String) in
        let fm = FileManager.default
        var moved = 0
        var log = "=== \(Date()) organize \(folder.path)\n"
        for (file, cat) in plan {
            let dir = folder.appendingPathComponent(cat)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(file.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
                n += 1
            }
            if (try? fm.moveItem(at: file, to: dest)) != nil {
                moved += 1
                log += "\(file.path)\t->\t\(dest.path)\n"
            }
        }
        return (moved, log)
        }.value
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Kiri-moves.log")
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(log.utf8)); try? h.close() }
        else { try? Data(log.utf8).write(to: logURL) }
        return "Tidied \(folder.lastPathComponent): moved \(moved) files into folders 🧹"
    }

    // MARK: helpers

    private static func shell(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
