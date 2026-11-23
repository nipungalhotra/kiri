import AppKit
import Foundation

/// "Open a PR": pushes your branch and opens a pull request, after you check the title and description.
/// Asks first, never force-pushes, and never pushes straight to main.
extension PetState {
    func openPullRequest() {
        guard let dir = projectURL else { say("Pick a project folder first 📁", for: 4); return }
        guard !busy else { say("One sec, I'm still working 🦉", for: 3); return }
        busy = true
        mood = .thinking
        activity = "Looking at your branch…"
        Task.detached {
            func fail(_ s: String) async { await MainActor.run { self.commitFinished(s) } }
            guard Git.isRepo(dir) else { await fail("\(dir.lastPathComponent) isn't a git repository."); return }
            guard GitHub.run(["auth", "status"], in: dir).code == 0 else { await fail("I need the GitHub CLI signed in: run `gh auth login` (🦉 → Setup Check… can open it)."); return }
            if !Git.run(["status", "--porcelain"], in: dir).out.isEmpty {
                await fail("You have uncommitted changes. Say “commit this” first, then “open a PR”."); return
            }
            let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
            var base = GitHub.run(["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], in: dir).out
            if base.isEmpty || base.contains(" ") { base = "main" }
            let baseBranch = base
            let existing = GitHub.run(["pr", "view", "--json", "url", "--jq", ".url"], in: dir)
            if existing.code == 0, existing.out.hasPrefix("http") {
                await MainActor.run {
                    self.commitFinished("This branch already has a PR: \(existing.out)", happy: true)
                    if let u = URL(string: existing.out) { NSWorkspace.shared.open(u) }
                }
                return
            }
            _ = Git.run(["fetch", "origin", base, "--quiet"], in: dir)
            let log = Git.run(["log", "--oneline", "origin/\(base)..HEAD"], in: dir).out
            let stat = Git.run(["diff", "--stat", "origin/\(base)...HEAD"], in: dir).out
            guard !log.isEmpty, !log.hasPrefix("fatal") else { await fail("There are no new commits on \(branch) compared with \(base)."); return }
            let prompt = """
            Write a GitHub pull request title and description for these commits. Reply in exactly this format:
            TITLE: <one line, under 70 characters>
            BODY:
            <2-6 short markdown bullet points about what changed and why>

            Commits:
            \(log.prefix(4000))

            Files changed:
            \(stat.prefix(3000))
            """
            await MainActor.run {
                self.activity = "Writing the PR description…"
                ClaudeRunner.quick(prompt, cwd: dir) { answer in
                    let text = answer ?? ""
                    let title = text.components(separatedBy: "\n").first { $0.hasPrefix("TITLE:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                        ?? log.components(separatedBy: "\n").first.map { String($0.drop { $0 != " " }).trimmingCharacters(in: .whitespaces) } ?? branch
                    let body = text.components(separatedBy: "BODY:").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    self.confirmPR(title: title, body: body.isEmpty ? log : body, branch: branch, base: baseBranch, in: dir)
                }
            }
        }
    }

    private func confirmPR(title: String, body: String, branch: String, base: String, in dir: URL) {
        busy = false
        activity = nil
        bubble = nil
        let onMain = branch == base || branch == "HEAD"
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Push and open a pull request into \(base)?"
        a.informativeText = onMain
            ? "You're on \(base), so Kiri will first create a new branch for these commits. Edit the title and description if you like."
            : "Kiri will push \(branch) to GitHub and open the PR. Edit the title and description if you like."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        let titleField = NSTextField(frame: NSRect(x: 0, y: 172, width: 440, height: 24))
        titleField.stringValue = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 164))
        let bodyView = NSTextView(frame: scroll.bounds)
        bodyView.string = body
        bodyView.isRichText = false
        bodyView.font = .systemFont(ofSize: 12)
        bodyView.autoresizingMask = [.width]
        scroll.documentView = bodyView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        box.addSubview(titleField)
        box.addSubview(scroll)
        a.accessoryView = box
        a.addButton(withTitle: "Push & Open PR")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { commitFinished("Okay, nothing was pushed."); return }
        let finalTitle = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        let finalBody = bodyView.string
        busy = true
        mood = .working
        activity = "Pushing to GitHub…"
        Task.detached {
            var head = branch
            if onMain {
                let slug = finalTitle.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
                    .split(separator: "-").prefix(5).joined(separator: "-")
                head = "kiri/" + (slug.isEmpty ? "changes" : slug)
                let b = Git.run(["switch", "-c", head], in: dir)
                guard b.code == 0 else { await MainActor.run { self.commitFinished("Couldn't create a branch: \(b.out.prefix(200))") }; return }
            }
            let push = Git.run(["push", "-u", "origin", head], in: dir)
            guard push.code == 0 else { await MainActor.run { self.commitFinished("git push failed: \(push.out.prefix(300))") }; return }
            let pr = GitHub.run(["pr", "create", "--base", base, "--head", head, "--title", finalTitle, "--body", finalBody], in: dir)
            let url = pr.out.components(separatedBy: "\n").last { $0.hasPrefix("http") }
            await MainActor.run {
                if pr.code == 0, let url {
                    self.commitFinished("Opened your pull request 🎉 \(url)", happy: true)
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    self.checkPRsNow()
                } else {
                    self.commitFinished("Pushed, but couldn't open the PR: \(pr.out.prefix(300))")
                }
            }
        }
    }
}
