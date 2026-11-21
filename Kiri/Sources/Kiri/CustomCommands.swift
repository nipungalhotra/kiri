import AppKit
import Foundation

/// Your own "Hey Hoot" commands, no coding in Kiri needed:
///  • a script in ~/Library/Application Support/Kiri/Commands (e.g. `start-standup.sh` → say "start standup")
///  • or a Shortcut whose name starts with "Kiri: " (e.g. "Kiri: Lights Off" → say "lights off")
/// They run only when you say or type the name yourself; Claude can't start them.
enum CustomCommands {
    struct Command: Identifiable, Equatable {
        enum Kind: Equatable { case script(URL), shortcut(String) }
        let name: String
        let kind: Kind
        var id: String { name }
    }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kiri/Commands")
    private static let scriptTypes: Set<String> = ["sh", "zsh", "command", "py"]
    nonisolated(unsafe) private static var shortcutNames: [String] = []

    /// Creates the folder with a short guide and one example the first time.
    static func prepareFolder() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let guide = """
        Kiri custom commands
        ====================
        Put a script here and say its name to Hoot (or type it in the chat).
          say-hello.sh      → "Hey Hoot, say hello"
          open-my-work.sh   → "open my work"
        Scripts run in your project folder with your normal PATH. $KIRI_PROJECT holds the project path.
        Supported: .sh .zsh .command (zsh) and .py (python3).

        Shortcuts work too: name a Shortcut "Kiri: Lights Off" and say "lights off".
        """
        try? guide.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let example = folder.appendingPathComponent("say-hello.sh")
        try? "#!/bin/zsh\necho \"Hello from your own Kiri command! 🦉 It's $(date +%H:%M).\"\n".write(to: example, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: example.path)
    }

    /// Reloads the Shortcuts list in the background (the `shortcuts` tool can take a moment).
    static func refreshShortcuts() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("Kiri: ") }
            DispatchQueue.main.async { shortcutNames = names }
        }
    }

    static func displayName(forFile url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").lowercased()
    }

    static func all() -> [Command] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let scripts = files.filter { scriptTypes.contains($0.pathExtension.lowercased()) }
            .map { Command(name: displayName(forFile: $0), kind: .script($0)) }
        let shortcuts = shortcutNames.map { Command(name: String($0.dropFirst(6)).lowercased(), kind: .shortcut($0)) }
        return (scripts + shortcuts).sorted { $0.name < $1.name }
    }

    /// "Hey Hoot, start standup please" → the "start standup" command.
    static func match(_ text: String, in commands: [Command]? = nil) -> Command? {
        var t = text.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for prefix in ["please ", "can you ", "run ", "do "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        for suffix in [" please", " now"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return (commands ?? all()).sorted { $0.name.count > $1.name.count }.first { t == $0.name }
    }

    /// Runs a command (60 s limit) and returns what it printed.
    static func run(_ c: Command, project: URL?) async -> String {
        await Task.detached { () -> String in
            let p = Process()
            switch c.kind {
            case .script(let url):
                p.executableURL = URL(fileURLWithPath: url.pathExtension.lowercased() == "py" ? "/usr/bin/env" : "/bin/zsh")
                p.arguments = url.pathExtension.lowercased() == "py" ? ["python3", url.path] : [url.path]
            case .shortcut(let name):
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["run", name]
            }
            var env = ClaudeRunner.environment
            env["KIRI_PROJECT"] = project?.path ?? ""
            p.environment = env
            p.currentDirectoryURL = project ?? URL(fileURLWithPath: NSHomeDirectory())
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return "Couldn't run “\(c.name)”: \(error.localizedDescription)" }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus != 0 { return "“\(c.name)” failed (exit \(p.terminationStatus))" + (text.isEmpty ? "" : ": \(text.prefix(400))") }
            return text.isEmpty ? "Done: \(c.name) ✅" : String(text.prefix(600))
        }.value
    }
}
