import CoreServices
import Foundation

/// Watches a project folder for saved files (FSEvents) and calls back, debounced.
/// Ignores build output, caches and VCS folders so test runs don't retrigger themselves.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?
    private static let ignoredFolders: Set<String> = [".git", ".build", "node_modules", "__pycache__", ".pytest_cache", "dist",
                                                      "build", "target", ".swiftpm", "DerivedData", ".venv", "venv", ".idea", ".vscode"]

    /// True for build output, caches and editor junk, including the folders themselves.
    static func isIgnored(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if let last = parts.last, last == ".DS_Store" || last.hasSuffix("~") || last.hasSuffix(".swp") { return true }
        return parts.contains { ignoredFolders.contains($0) }
    }

    init?(folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let relevant = list.prefix(count).contains { !FolderWatcher.isIgnored($0) }
            if relevant { me.schedule() }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    deinit {
        pending?.cancel()
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}

/// Failed terminal commands, reported by a small zsh hook that appends lines to a file Kiri watches.
/// Line format: <exit code>\t<working directory>\t<command>
final class TerminalWatcher {
    struct Failure { let code: Int; let dir: String; let command: String }

    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let eventsFile = support.appendingPathComponent("terminal-events.log")
    static let hookFile = support.appendingPathComponent("kiri-hook.zsh")
    static let sourceLine = "[ -f \"$HOME/Library/Application Support/Kiri/kiri-hook.zsh\" ] && source \"$HOME/Library/Application Support/Kiri/kiri-hook.zsh\"  # Kiri terminal watching"

    static let hookScript = """
    # Kiri: tell the owl when a terminal command fails (exit code, folder, command). Nothing else is sent.
    kiri_preexec() { KIRI_LAST_CMD="$1"; }
    kiri_precmd() {
      local kiri_status=$?
      if [[ -n "$KIRI_LAST_CMD" && $kiri_status -ne 0 && $kiri_status -ne 130 ]]; then
        printf '%s\\t%s\\t%s\\n' "$kiri_status" "$PWD" "${KIRI_LAST_CMD//$'\\n'/ }" >> "$HOME/Library/Application Support/Kiri/terminal-events.log"
      fi
      KIRI_LAST_CMD=""
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec kiri_preexec
    add-zsh-hook precmd kiri_precmd
    """

    static var isInstalled: Bool {
        let rc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        return (try? String(contentsOf: rc, encoding: .utf8))?.contains("kiri-hook.zsh") ?? false
    }

    /// Writes the hook file and adds one `source` line to ~/.zshrc (only when the user clicks to do so).
    static func install() throws {
        try hookScript.write(to: hookFile, atomically: true, encoding: .utf8)
        let rc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        var text = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        if !text.contains("kiri-hook.zsh") {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n\(sourceLine)\n"
            try text.write(to: rc, atomically: true, encoding: .utf8)
        }
    }

    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private let onFailure: (Failure) -> Void

    init(onFailure: @escaping (Failure) -> Void) {
        self.onFailure = onFailure
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.eventsFile.path) { fm.createFile(atPath: Self.eventsFile.path, contents: nil) }
        offset = (try? fm.attributesOfItem(atPath: Self.eventsFile.path)[.size] as? UInt64) ?? 0
        let fd = open(Self.eventsFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.readNew() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func readNew() {
        guard let h = try? FileHandle(forReadingFrom: Self.eventsFile) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset += UInt64(data.count)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let code = Int(f[0]) else { continue }
            onFailure(Failure(code: code, dir: f[1], command: f[2]))
        }
    }

    deinit { source?.cancel() }
}
