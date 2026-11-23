import AVFoundation
import AppKit
import Foundation
import Speech

enum SFSpeechRecognizerStatus {
    static var allowed: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

/// The newer helpers: built-in voice/typed commands, PR buddy, clipboard and Xcode help,
/// morning greeting, daily brief, achievements.
extension PetState {
    // MARK: Built-in commands (handled on the Mac, no Claude needed)

    enum BuiltIn: Equatable { case commit, brief, clipboard, achievements, openPR, custom(CustomCommands.Command) }

    nonisolated static func builtIn(for text: String, commands: [CustomCommands.Command] = []) -> BuiltIn? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,").union(.whitespacesAndNewlines))
        func any(_ phrases: [String]) -> Bool { phrases.contains { t == $0 || t.hasPrefix($0 + " ") } }
        if let c = CustomCommands.match(text, in: commands) { return .custom(c) }
        if any(["commit", "commit this", "commit my changes", "commit my code", "commit the changes", "make a commit", "please commit"]) { return .commit }
        if any(["brief me", "daily brief", "my daily brief", "give me my daily brief", "good morning", "what's my day", "whats my day", "what's my day like", "plan my day"]) { return .brief }
        if any(["explain what i copied", "explain my clipboard", "what did i copy", "explain the clipboard", "explain this error i copied", "explain what i just copied"]) { return .clipboard }
        if any(["open a pr", "open a pull request", "create a pr", "create a pull request", "make a pr", "raise a pr", "push this",
                "push and open a pr", "push my branch", "open pr", "create pr"]) { return .openPR }
        if any(["achievements", "show achievements", "my achievements", "what have you earned", "show my progress"]) { return .achievements }
        return nil
    }

    /// Returns true when the text was one of Kiri's own commands.
    func handleBuiltIn(_ text: String) -> Bool {
        guard let b = Self.builtIn(for: text, commands: CustomCommands.all()) else { return false }
        Log.write("built-in command \(b)")
        if b != .clipboard { messages.append(ChatMessage(role: .user, text: text)) }
        switch b {
        case .commit: commitChanges()
        case .brief: dailyBrief()
        case .clipboard: explainClipboard()
        case .achievements: showAchievements()
        case .openPR: chatOpen = true; openPullRequest()
        case .custom(let c): runCustom(c)
        }
        return true
    }

    func runCustom(_ c: CustomCommands.Command) {
        busy = true
        mood = .working
        activity = "Running “\(c.name)”…"
        Task { @MainActor in
            let out = await CustomCommands.run(c, project: projectURL)
            busy = false
            activity = nil
            note("🦉 \(out)")
            say(out.count > 120 ? String(out.prefix(120)) + "…" : out, for: 6)
            if speakReplies { Voice.shared.speak(out) }
            feel(out.contains("failed") ? .sad : .happy, for: 2)
        }
    }

    // MARK: Wake word test

    /// For 20 s, show live what the mic hears (on screen only), so you can see how "Hey Hoot" comes out.
    func testWakeWord() {
        let wake = WakeWord.shared
        guard heyHoot else { say("Turn on 🦉 → Voice → Listen for “Hey Hoot” first", for: 5); return }
        guard SFSpeechRecognizerStatus.allowed else { say("I need Microphone and Speech Recognition: 🦉 → Setup Check…", mood: .sad, for: 6); return }
        wake.testUntil = Date().addingTimeInterval(20)
        wake.onTestHeard = { [weak self] text in self?.say("I hear: “\(text.suffix(60))”", for: 4) }
        say("Testing for 20 seconds 🎤 Say “Hey Hoot, open Safari” and watch here.", mood: .happy, for: 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 21) { [weak self] in
            wake.onTestHeard = nil
            self?.say("Test done. If I never reacted, try saying it a bit slower, closer to the Mac 🦉", for: 6)
        }
    }

    // MARK: Morning & brief

    /// Once a day: "Morning! Yesterday you were…" (only if there's earlier work to talk about).
    func morningGreeting() -> String? {
        let day = Date().formatted(.iso8601.year().month().day())
        let h = Calendar.current.component(.hour, from: Date())
        guard greetedDay != day, h >= 5, h < 12, let line = ProjectMemory.morningLine(for: projectURL) else { return nil }
        greetedDay = day
        return "Morning! ☀️ \(line) Say “brief me” for your day."
    }

    func dailyBrief() {
        chatOpen = true
        mood = .thinking
        activity = "Putting your day together…"
        Task { @MainActor in
            let text = await DailyBrief.compose(project: projectURL, testsPassed: lastTestsPassedPublic, prs: openPRs)
            activity = nil
            messages.append(ChatMessage(role: .kiri, text: text))
            feel(.happy, for: 3)
            if speakReplies { Voice.shared.speak(text) }
        }
    }

    // MARK: PR buddy

    func prEvent(_ e: PRWatcher.Event) {
        let readTools = ["Bash(gh pr checks:*)", "Bash(gh run view:*)", "Bash(gh pr view:*)", "Bash(gh pr diff:*)",
                         "Bash(git log:*)", "Bash(git diff:*)", "Bash(git status:*)"]
        switch e {
        case .ciFailed(let pr):
            guard !busy else { return }
            PetSignals.shared.surprise(for: 0.8)
            fixRequest = (prompt: "CI is failing on my pull request #\(pr.number) “\(pr.title)” (branch \(pr.branch)). "
                          + "Failing checks: \(pr.failing.joined(separator: ", ")). Use `gh pr checks \(pr.number)` and "
                          + "`gh run view <run-id> --log-failed` to find out why, then fix it in the code here."
                          + (allowEdits ? "" : " (You can't edit files right now, so explain the fix and show the exact change.)"),
                          display: "Why is CI failing on #\(pr.number)? 🔴", cwd: projectURL, tools: readTools, isFix: true)
            fixLabel = "Fix it"
            offerFix = true
            mood = .sad
            say("CI failed on #\(pr.number) “\(pr.title.prefix(40))” 😢 Want me to fix it?", for: nil)
            if speakReplies && !quiet { Voice.shared.speak("CI failed on your pull request. Want me to fix it?") }
        case .ciPassed(let pr):
            guard !quiet else { return }
            say("CI is green on #\(pr.number)! ✅", for: 5)
            feel(.happy, for: 3)
        case .newReview(let pr):
            guard !busy, !offerFix, !quiet else { return }
            let who = pr.lastReviewer.map { "@\($0)" } ?? "Someone"
            let verdict = pr.lastReviewState == "APPROVED" ? " approved it 🎉" : (pr.lastReviewState == "CHANGES_REQUESTED" ? " asked for changes" : " left a review")
            if pr.lastReviewState == "APPROVED" { say("\(who)\(verdict) on #\(pr.number)!", for: 6); feel(.happy, for: 3); return }
            fixRequest = (prompt: "There's new review feedback on my pull request #\(pr.number) “\(pr.title)”. Read it with "
                          + "`gh pr view \(pr.number) --comments` (and `gh pr diff \(pr.number)` if useful), explain briefly what the reviewer "
                          + "is asking for, and suggest the exact changes.",
                          display: "What did \(who) say on #\(pr.number)? 💬", cwd: projectURL, tools: readTools, isFix: false)
            fixLabel = "Explain"
            offerFix = true
            say("\(who)\(verdict) on #\(pr.number) 💬 Want me to explain?", for: nil)
        }
    }

    // MARK: Clipboard

    func copiedError(_ text: String) {
        guard !busy, !offerFix, !testing, !quiet else { return }
        fixRequest = (prompt: clipboardPrompt(text), display: "Explain the error I copied 📋", cwd: projectURL, tools: [], isFix: false)
        fixLabel = "Explain"
        offerFix = true
        PetSignals.shared.surprise(for: 0.5)
        say("You copied an error 📋 Want me to explain it?", for: 12)
    }

    func explainClipboard() {
        guard let text = ClipboardWatcher.readNow() else { say("Your clipboard is empty 📋", for: 4); return }
        chatOpen = true
        send(clipboardPrompt(text), shownAs: "Explain what I copied 📋")
    }

    private func clipboardPrompt(_ text: String) -> String {
        "I copied this:\n\n```\n\(text.prefix(6000))\n```\n\nExplain briefly what it means, the likely cause, and how to fix it "
            + "(look at the project files if it helps)."
    }

    // MARK: Xcode

    func xcodeFailed(_ f: XcodeWatcher.Failure) {
        guard !busy else { return }
        let short = f.errors.map { line -> String in
            let parts = line.components(separatedBy: ": error: ")
            let file = (parts.first.map { ($0 as NSString).lastPathComponent }) ?? ""
            return "\(file): \(parts.last ?? line)"
        }
        fixRequest = (prompt: "My Xcode build of \(f.project) failed with:\n\n```\n\(f.errors.joined(separator: "\n"))\n```\n\n"
                      + "Find the cause in the code and fix it." + (allowEdits ? "" : " (You can't edit files right now, so explain the fix and show the exact change.)"),
                      display: "Fix my Xcode build errors 🛠️", cwd: f.folder ?? projectURL, tools: [], isFix: true)
        fixLabel = "Fix it"
        offerFix = true
        mood = .sad
        PetSignals.shared.surprise(for: 0.6)
        say("\(f.project) build failed: \(short.first?.prefix(70) ?? "")\(f.errors.count > 1 ? " (+\(f.errors.count - 1) more)" : "") 😣", for: nil)
        if speakReplies && !quiet { Voice.shared.speak("Your Xcode build failed. Want me to fix it?") }
    }

    // MARK: Evolution

    func celebrate(_ a: Evolution.Accessory) {
        say("Level up! I earned my \(a.title) ✨", for: 8)
        feel(.happy, for: 5)
        note("🏆 Hoot unlocked \(a.title) (\(a.goal)).")
        if speakReplies { Voice.shared.speak("Level up! I earned new \(a.rawValue == "glasses" ? "glasses" : "a " + a.rawValue)!") }
    }

    func showAchievements() {
        chatOpen = true
        let e = Evolution.shared
        messages.append(ChatMessage(role: .kiri, text: "Here's what I've earned so far:\n\(e.summary)\n\nTest runs passed: \(e.passes) · fixes: \(e.fixes) · best streak: \(e.bestStreak)"))
        feel(.happy, for: 2)
    }
}
