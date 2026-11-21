import AppKit
import ScreenCaptureKit

/// Takes a screenshot of the main display (without Kiri's own windows) for "What's on my screen?".
/// Needs the Screen Recording permission; macOS asks the first time.
enum ScreenHelp {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri/screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Phrases that mean "look at my screen".
    static func wantsScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["my screen", "on screen", "on the screen", "this screen", "what am i looking at", "screenshot",
                "what's this error", "whats this error", "look at this", "see my screen"].contains { t.contains($0) }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording access (shows the system prompt the first time).
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func capture() async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "Kiri", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        // Keep it readable but small enough to send quickly.
        let scale = min(1.0, 1600.0 / Double(display.width))
        cfg.width = Int(Double(display.width) * scale * 2)
        cfg.height = Int(Double(display.height) * scale * 2)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        // remove old screenshots so they don't pile up
        if let old = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            old.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let url = folder.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Kiri", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't save screenshot"])
        }
        try png.write(to: url)
        return url
    }
}

/// "Allow this?" — a clear yes/no question before anything risky.
@MainActor
enum Approval {
    static func ask(_ title: String, _ detail: String, allow: String = "Allow") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: allow)
        a.addButton(withTitle: "Don't Allow")
        let ok = a.runModal() == .alertFirstButtonReturn
        Log.write("approval \(Log.secret(title, max: 80)) -> \(ok ? "allowed" : "denied")")
        return ok
    }
}
