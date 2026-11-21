import AppKit
import Foundation

/// Runs `git` / `gh` with the user's PATH. Never on the main thread.
enum Git {
    @discardableResult
    static func run(_ args: [String], in dir: URL, input: String? = nil) -> (code: Int32, out: String) {
        tool("git", args, in: dir, input: input)
    }

    static func isRepo(_ dir: URL) -> Bool { run(["rev-parse", "--is-inside-work-tree"], in: dir).out == "true" }

    static func tool(_ name: String, _ args: [String], in dir: URL, input: String? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [name] + args
        p.currentDirectoryURL = dir
        p.environment = ClaudeRunner.environment
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        guard (try? p.run()) != nil else { return (-1, "") }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum GitHub {
    static func run(_ args: [String], in dir: URL) -> (code: Int32, out: String) { Git.tool("gh", args, in: dir) }
}

// MARK: PR buddy

/// Every few minutes, looks at your open pull requests in the current project (via `gh`) and
/// reports when CI starts failing, goes green again, or someone leaves a review.
@MainActor
final class PRWatcher {
    struct PR: Equatable {
        let number: Int
        let title: String
        let url: String
        let branch: String
        let failing: [String]
        let pending: Bool
        let feedback: Int               // reviews + comments
        let lastReviewer: String?
        let lastReviewState: String?
        var ciState: String { !failing.isEmpty ? "failed" : (pending ? "pending" : "passed") }
    }
    enum Event {
        case ciFailed(PR)
        case ciPassed(PR)
        case newReview(PR)
    }

    private var timer: Timer?
    private var known: [Int: PR] = [:]
    private(set) var current: [PR] = []
    private var dir: URL?
    let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }

    func watch(_ project: URL?) {
        timer?.invalidate()
        known = [:]
        current = []
        dir = project
        guard project != nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
    }

    func poll() {
        guard let dir else { return }
        Task.detached {
            guard Git.isRepo(dir) else { return }
            let r = GitHub.run(["pr", "list", "--author", "@me", "--state", "open", "--limit", "10",
                                "--json", "number,title,url,headRefName,statusCheckRollup,reviews,comments"], in: dir)
            guard r.code == 0 else { return }
            let prs = Self.parse(r.out)
            await MainActor.run { self.update(prs) }
        }
    }

    nonisolated static func parse(_ json: String) -> [PR] {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let n = o["number"] as? Int else { return nil }
            let checks = o["statusCheckRollup"] as? [[String: Any]] ?? []
            var failing: [String] = []
            var pending = false
            for c in checks {
                let name = (c["name"] as? String) ?? (c["context"] as? String) ?? "check"
                let conclusion = ((c["conclusion"] as? String) ?? (c["state"] as? String) ?? "").uppercased()
                let status = ((c["status"] as? String) ?? "").uppercased()
                if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) { failing.append(name) }
                else if conclusion.isEmpty || conclusion == "PENDING" || ["IN_PROGRESS", "QUEUED", "PENDING", "WAITING"].contains(status) { pending = true }
            }
            let reviews = o["reviews"] as? [[String: Any]] ?? []
            let comments = o["comments"] as? [[String: Any]] ?? []
            let last = reviews.last
            let reviewer = ((last?["author"] as? [String: Any])?["login"] as? String)
                ?? ((comments.last?["author"] as? [String: Any])?["login"] as? String)
            return PR(number: n, title: o["title"] as? String ?? "", url: o["url"] as? String ?? "",
                      branch: o["headRefName"] as? String ?? "", failing: failing, pending: pending,
                      feedback: reviews.count + comments.count, lastReviewer: reviewer,
                      lastReviewState: last?["state"] as? String)
        }
    }

    /// Compare with what we saw last time and report changes (a PR seen for the first time: only red CI).
    func update(_ prs: [PR]) {
        current = prs
        for pr in prs {
            let old = known[pr.number]
            if let old {
                if pr.ciState == "failed" && old.ciState != "failed" { onEvent(.ciFailed(pr)) }
                if pr.ciState == "passed" && old.ciState == "failed" { onEvent(.ciPassed(pr)) }
                if pr.feedback > old.feedback { onEvent(.newReview(pr)) }
            } else {
                if pr.ciState == "failed" { onEvent(.ciFailed(pr)) }
            }
            known[pr.number] = pr
        }
        Log.write("pr check: \(prs.count) open, \(prs.filter { $0.ciState == "failed" }.count) failing")
    }
}

// MARK: Commit helper

extension PetState {
    /// "Commit this": Claude writes the message from your diff, you check/edit it, then Kiri commits (never pushes).
    func commitChanges() {
        guard let dir = projectURL else { say("Pick a project folder first 📁", for: 4); return }
        guard !busy else { say("One sec, I'm still working 🦉", for: 3); return }
        busy = true
        mood = .thinking
        activity = "Reading your changes…"
        if !chatOpen { say("Writing a commit message… ✍️", for: nil) }
        Task.detached {
            guard Git.isRepo(dir) else {
                await MainActor.run { self.commitFinished("\(dir.lastPathComponent) isn't a git repository yet. Run `git init` first.") }
                return
            }
            let status = Git.run(["status", "--porcelain"], in: dir).out
            guard !status.isEmpty else { await MainActor.run { self.commitFinished("Nothing to commit, everything's saved ✨") }; return }
            var diff = Git.run(["diff", "HEAD"], in: dir).out
            if diff.isEmpty || diff.hasPrefix("fatal") { diff = Git.run(["diff"], in: dir).out }
            let prompt = """
            Write a git commit message for these changes. Reply with ONLY the message: a summary line under 70 \
            characters in the imperative mood, then optionally a blank line and up to 4 short "- " lines. No code fences, no quotes.

            Changed files (git status):
            \(status.prefix(3000))

            Diff:
            \(diff.prefix(12000))
            """
            await MainActor.run {
                self.activity = "Writing a commit message…"
                ClaudeRunner.quick(prompt, cwd: dir) { message in
                    guard let message, !message.isEmpty else {
                        self.commitFinished("I couldn't write a message (is Claude signed in?). 🦉 → Setup Check… can help.")
                        return
                    }
                    self.confirmCommit(message: message, status: status, in: dir)
                }
            }
        }
    }

    private func confirmCommit(message: String, status: String, in dir: URL) {
        busy = false
        activity = nil
        bubble = nil
        let files = status.split(separator: "\n")
        let secretLike = files.filter { f in [".env", "credentials", ".pem", "id_rsa", ".p12", "secret"].contains { f.lowercased().contains($0) } }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Commit \(files.count) changed file\(files.count == 1 ? "" : "s") in \(dir.lastPathComponent)?"
        var info = "Edit the message if you like. Kiri runs git add -A and git commit. It never pushes."
        if !secretLike.isEmpty { info += "\n\n⚠️ These look like secrets, check before committing:\n" + secretLike.prefix(5).joined(separator: "\n") }
        a.informativeText = info
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        let text = NSTextView(frame: scroll.bounds)
        text.string = message
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        a.accessoryView = scroll
        a.addButton(withTitle: "Commit")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { commitFinished("Okay, I didn't commit anything."); return }
        let final = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { commitFinished("Empty message, so I didn't commit."); return }
        Task.detached {
            Git.run(["add", "-A"], in: dir)
            let r = Git.run(["commit", "-F", "-"], in: dir, input: final + "\n")
            let hash = Git.run(["rev-parse", "--short", "HEAD"], in: dir).out
            await MainActor.run {
                if r.code == 0 {
                    self.commitFinished("Committed \(hash): \(final.split(separator: "\n").first ?? "") ✅", happy: true)
                } else {
                    self.commitFinished("git commit failed: \(r.out.prefix(300))")
                }
            }
        }
    }

    func commitFinished(_ text: String, happy: Bool = false) {
        busy = false
        activity = nil
        note("🦉 \(text)")
        say(text, for: 6)
        if happy { feel(.happy, for: 3) } else { settle() }
        if speakReplies { Voice.shared.speak(happy ? "Committed!" : text) }
    }
}
