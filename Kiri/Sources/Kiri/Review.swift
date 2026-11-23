import AppKit
import SwiftUI

// MARK: Undo snapshot

/// Before Claude may edit files, Kiri copies the project's files (small text/code files, skipping build
/// folders) to ~/Library/Caches/Kiri/undo. "Undo" puts them back; files Claude created go to the Trash.
final class UndoSnapshot: @unchecked Sendable {
    let root: URL
    let backup: URL
    /// Every file that existed (relative path), even ones too big to copy.
    private(set) var existing: Set<String> = []
    private(set) var copied: Set<String> = []

    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri/undo")
    static let maxFile = 2_000_000
    static let maxTotal = 60_000_000

    private init(root: URL) {
        self.root = root.standardizedFileURL
        backup = Self.folder.appendingPathComponent(UUID().uuidString)
    }

    /// Slow-ish (copies files): call off the main thread.
    static func take(_ root: URL) -> UndoSnapshot? {
        let fm = FileManager.default
        cleanOld()
        let snap = UndoSnapshot(root: root)
        guard (try? fm.createDirectory(at: snap.backup, withIntermediateDirectories: true)) != nil,
              let walker = fm.enumerator(at: snap.root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return nil }
        var total = 0, count = 0
        for case let url as URL in walker {
            let rel = snap.relative(url)
            if FolderWatcher.isIgnored(rel) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            count += 1
            if count > 20_000 { break }
            snap.existing.insert(rel)
            let size = v.fileSize ?? 0
            guard size <= maxFile, total + size <= maxTotal else { continue }
            let dest = snap.backup.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: url, to: dest)) != nil { snap.copied.insert(rel); total += size }
        }
        Log.write("undo snapshot: \(snap.copied.count)/\(snap.existing.count) files, \(total / 1024) KB")
        return snap
    }

    func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }

    func canUndo(_ file: URL) -> Bool {
        let rel = relative(file)
        return copied.contains(rel) || !existing.contains(rel)
    }

    /// Put one file back. Returns false if it couldn't be undone.
    @discardableResult
    func restore(_ file: URL) -> Bool {
        let fm = FileManager.default
        let rel = relative(file)
        if copied.contains(rel) {
            let src = backup.appendingPathComponent(rel)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: file.path) { _ = try? fm.replaceItemAt(file, withItemAt: copyToTemp(src)) }
            else { try? fm.copyItem(at: src, to: file) }
            return true
        }
        if !existing.contains(rel) {                         // Claude created it: move to Trash (recoverable)
            if fm.fileExists(atPath: file.path) { return (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil }
            return true
        }
        return false
    }

    func backupCopy(of file: URL) -> URL? {
        let rel = relative(file)
        return copied.contains(rel) ? backup.appendingPathComponent(rel) : nil
    }

    func discard() { try? FileManager.default.removeItem(at: backup) }

    private func copyToTemp(_ src: URL) -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
        try? FileManager.default.copyItem(at: src, to: tmp)
        return tmp
    }

    /// Snapshots older than a day are no longer useful.
    private static func cleanOld() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for i in items {
            if let d = try? i.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(d) > 86_400 {
                try? fm.removeItem(at: i)
            }
        }
    }
}

// MARK: Review

/// "I changed 2 files. Keep / Undo / Compare" after Claude edits code.
struct ChangeReview: Identifiable {
    let id = UUID()
    let title: String
    let files: [URL]
    let snapshot: UndoSnapshot
    var names: String {
        let n = files.map(\.lastPathComponent)
        return n.count <= 3 ? n.joined(separator: ", ") : n.prefix(3).joined(separator: ", ") + " +\(n.count - 3)"
    }
}

/// Files a Claude run changed: edit/write tool calls that weren't refused.
enum EditTracker {
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    static func changedFiles(calls: [String: (name: String, detail: String)], denied: [(name: String, detail: String)], root: URL) -> [URL] {
        let refused = Set(denied.map(\.detail))
        var seen = Set<String>(), out: [URL] = []
        for c in calls.values where editTools.contains(c.name) && !c.detail.isEmpty && !refused.contains(c.detail) {
            let url = c.detail.hasPrefix("/") ? URL(fileURLWithPath: c.detail) : root.appendingPathComponent(c.detail)
            if seen.insert(url.standardizedFileURL.path).inserted { out.append(url.standardizedFileURL) }
        }
        return out.sorted { $0.path < $1.path }
    }
}

extension PetState {
    /// Copy the project first when Claude may edit, then run `start` (on the main thread).
    func withUndoSnapshot(for dir: URL, edits: Bool, _ start: @escaping @MainActor (UndoSnapshot?) -> Void) {
        guard edits, dir != Self.workspaceDir else { start(nil); return }
        activity = "Getting ready…"
        Task.detached {
            let snap = UndoSnapshot.take(dir)
            await MainActor.run { start(snap) }
        }
    }

    func offerReview(title: String, files: [URL], snapshot: UndoSnapshot?) {
        guard let snapshot else { return }
        guard !files.isEmpty else { snapshot.discard(); return }
        reviews.append(ChangeReview(title: title, files: files, snapshot: snapshot))
        if reviews.count == 1 {
            say("I changed \(files.count) file\(files.count == 1 ? "" : "s"): \(reviews[0].names). Keep the changes?", for: nil)
        }
    }

    func keepChanges() {
        guard !reviews.isEmpty else { return }
        let r = reviews.removeFirst()
        r.snapshot.discard()
        note("👍 Kept changes to \(r.names).")
        bubble = nil
        feel(.happy, for: 2)
        nextReview()
    }

    func undoChanges() {
        guard !reviews.isEmpty else { return }
        let r = reviews.removeFirst()
        let failed = r.files.filter { !r.snapshot.restore($0) }
        r.snapshot.discard()
        if failed.isEmpty {
            note("↩️ Undid changes to \(r.names).")
            say("Undone ↩️ Everything is back how it was.", for: 4)
        } else {
            note("↩️ Undid most changes, but couldn't restore \(failed.map(\.lastPathComponent).joined(separator: ", ")) (too big to back up).")
            say("Mostly undone, one file was too big to back up 😕", for: 5)
        }
        Log.write("undo: \(r.files.count - failed.count)/\(r.files.count) files restored")
        if watchTests { runTests(silent: true) }
        nextReview()
    }

    /// Opens Apple's FileMerge to compare before/after (falls back to showing the file in Finder).
    func compareChanges() {
        guard let r = reviews.first, let file = r.files.first else { return }
        guard let before = r.snapshot.backupCopy(of: file) else { NSWorkspace.shared.activateFileViewerSelecting(r.files); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
        p.arguments = [before.path, file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) == nil { NSWorkspace.shared.activateFileViewerSelecting(r.files) }
    }

    private func nextReview() {
        if let r = reviews.first { say("Also changed \(r.names) (\(r.title.prefix(30))). Keep?", for: nil) }
    }
}

/// Keep / Undo / Compare buttons (chat, bubble and notch).
struct ReviewBar: View {
    @ObservedObject var state: PetState
    var dark = false

    var body: some View {
        if let r = state.reviews.first {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.clock").foregroundStyle(.purple)
                Text("Changed \(r.names)").font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(dark ? .white : .primary)
                Spacer(minLength: 4)
                Button("Keep") { state.keepChanges() }.buttonStyle(.borderedProminent).tint(.green)
                Button("Undo") { state.undoChanges() }.buttonStyle(.bordered)
                Button { state.compareChanges() } label: { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(.bordered).help("Compare before and after")
            }
            .controlSize(.small)
        }
    }
}
