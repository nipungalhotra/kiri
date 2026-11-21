import Foundation

/// Small diagnostic log at ~/Library/Logs/Kiri.log (readable only by you).
///
/// Private by default: what you say or type, Claude's replies, and terminal commands are written
/// only as a length ("[42 chars]"). Run Kiri with `--verbose-log` (or `KIRI_VERBOSE_LOG=1`) to log the
/// full text while debugging; secret-looking values are masked even then. The log is capped at 1 MB.
enum Log {
    static let url: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Kiri.log")
    private static let queue = DispatchQueue(label: "kiri.log")
    private static let maxBytes: UInt64 = 1_000_000
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let verbose = CommandLine.arguments.contains("--verbose-log")
        || ProcessInfo.processInfo.environment["KIRI_VERBOSE_LOG"] != nil

    /// Use for anything personal: prompts, transcripts, replies, commands, file contents.
    static func secret(_ text: some StringProtocol, max: Int = 300) -> String {
        verbose ? redact(String(text.prefix(max))) : "[\(text.count) chars]"
    }

    /// Mask API keys, tokens and passwords so they never land on disk.
    static func redact(_ s: String) -> String {
        var out = s
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{12,}"#,                                   // Anthropic / OpenAI style keys
            #"gh[pousr]_[A-Za-z0-9]{20,}"#,                               // GitHub tokens
            #"AKIA[0-9A-Z]{16}"#,                                         // AWS access keys
            #"(?i)bearer\s+[A-Za-z0-9._\-]{12,}"#,
            #"(?i)((?:api[_-]?key|token|secret|password|passwd|pwd)\s*[=:]\s*)\S+"#,
        ]
        for p in patterns {
            let template = p.contains("((?:api") ? "$1[redacted]" : "[redacted]"
            out = out.replacingOccurrences(of: p, with: template, options: .regularExpression)
        }
        return out
    }

    /// Run once at launch: drop logs written by older versions (they could hold prompts),
    /// lock the file to the current user, and trim it when it grows past 1 MB.
    static func prepare() {
        queue.sync {
            let fm = FileManager.default
            let d = UserDefaults.standard
            if !d.bool(forKey: "privateLogV1") {
                try? fm.removeItem(at: url)
                d.set(true, forKey: "privateLogV1")
            }
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(redact(message))\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
