import AppKit
import Foundation

// MARK: Clipboard

/// Notices when you copy an error message and offers to explain it.
/// macOS asks before an app reads the clipboard on its own, so this only runs automatically when you've
/// set Kiri to "Allow" in Privacy & Security → Paste from Other Apps. Otherwise use 🦉 → Explain What I Copied.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastOffered = ""
    let onError: (String) -> Void

    static var autoAllowed: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysAllow }
        return true
    }

    init(onError: @escaping (String) -> Void) {
        self.onError = onError
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }   // reading the count never triggers a prompt
        lastCount = pb.changeCount
        guard Self.autoAllowed, UserDefaults.standard.object(forKey: "watchClipboard") as? Bool ?? true else { return }
        let types = pb.types ?? []
        // password managers mark secrets as concealed/transient: never look at those
        if types.contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" }) { return }
        guard let s = pb.string(forType: .string), s != lastOffered, Self.looksLikeError(s) else { return }
        lastOffered = s
        onError(s)
    }

    /// Text that is clearly an error, stack trace or failed build (not just any text containing "error").
    nonisolated static func looksLikeError(_ s: String) -> Bool {
        guard (15...20000).contains(s.count) else { return false }
        let patterns = [
            #"Traceback \(most recent call last\)"#, #"\b\w*(Error|Exception):\s"#, #"(?m)^\s*(error|fatal)(\[\w+\])?:\s"#,
            #":\d+:\d+:\s+error:"#, #"npm ERR!"#, #"Uncaught \w+"#, #"panic: "#, #"Segmentation fault"#,
            #"(?m)^\s+at .+\(.+:\d+:\d+\)"#, #"(?m)^\s+at [\w.$<>]+\(.*\.(java|kt):\d+\)"#, #"Fatal error:"#,
            #"command not found"#, #"No such file or directory"#, #"BUILD FAILED"#, #"\bFAILED\b.*\btest"#,
        ]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    /// What you copied right now (you asked, so this is a normal user-initiated paste).
    static func readNow() -> String? {
        let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}

// MARK: Xcode builds

/// Watches Xcode's build logs. When a build fails, pulls out the compiler errors so Hoot can explain them.
@MainActor
final class XcodeWatcher {
    struct Failure {
        let errors: [String]
        let project: String
        let folder: URL?
    }

    private var timer: Timer?
    private var newest = Date()
    private var lastFailed = false
    nonisolated static let derivedData = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let onFailure: (Failure) -> Void
    let onFixed: (String) -> Void

    init(onFailure: @escaping (Failure) -> Void, onFixed: @escaping (String) -> Void) {
        self.onFailure = onFailure
        self.onFixed = onFixed
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in MainActor.assumeIsolated { self.scan() } }
    }

    private func scan() {
        let since = newest
        Task.detached {
            guard let log = Self.latestLog(after: since) else { return }
            let text = Self.unzip(log.url)
            let errors = Self.errors(in: text)
            let project = log.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent.components(separatedBy: "-").dropLast().joined(separator: "-")
            await MainActor.run {
                self.newest = log.date
                if errors.isEmpty {
                    if self.lastFailed { self.onFixed(project) }
                    self.lastFailed = false
                } else {
                    self.lastFailed = true
                    self.onFailure(Failure(errors: errors, project: project, folder: Self.projectFolder(for: errors)))
                }
            }
        }
    }

    nonisolated private static func latestLog(after date: Date) -> (url: URL, date: Date)? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil) else { return nil }
        var best: (URL, Date)?
        for p in projects {
            let dir = p.appendingPathComponent("Logs/Build")
            guard let logs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for l in logs where l.pathExtension == "xcactivitylog" {
                guard let d = try? l.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > date else { continue }
                if best == nil || d > best!.1 { best = (l, d) }
            }
        }
        return best
    }

    nonisolated private static func unzip(_ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// "/path/File.swift:12:5: error: cannot find 'x' in scope" lines, de-duplicated, at most 8.
    nonisolated static func errors(in log: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(/[^\s:"]+\.(?:swift|m|mm|c|cc|cpp|h|hpp|metal)):(\d+):(\d+): error: ([^\r\n\u0000"]{3,300})"#) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
            guard let r = Range(m.range, in: log) else { continue }
            var line = String(log[r])
            // the log stores strings with a length prefix; cut anything after the message
            if let next = line.range(of: #"\s/\S+:\d+:\d+: "#, options: .regularExpression) { line = String(line[..<next.lowerBound]) }
            if let cut = line.range(of: #"\d+\"$"#, options: .regularExpression) { line.removeSubrange(cut) }
            line = line.trimmingCharacters(in: .whitespaces)
            if seen.insert(line).inserted { out.append(line) }
            if out.count == 8 { break }
        }
        return out
    }

    /// The folder holding the .xcodeproj / Package.swift for the first erroring file.
    nonisolated static func projectFolder(for errors: [String]) -> URL? {
        guard let path = errors.first?.components(separatedBy: ":").first else { return nil }
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" && dir.path != NSHomeDirectory() {
            if let items = try? fm.contentsOfDirectory(atPath: dir.path),
               items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Package.swift" }) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
