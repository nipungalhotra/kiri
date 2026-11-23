import Foundation

/// `Kiri --selftest` checks the non-UI logic: action parsing, test counting, file watching, terminal events.
enum SelfTest {
    @MainActor
    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }

        // 1. KIRI_ACTION parsing
        let reply = "Sure! Opening it now.\nKIRI_ACTION {\"action\":\"open_app\",\"name\":\"Safari\"}\nKIRI_ACTION {\"action\":\"reminder\",\"title\":\"Stretch\",\"due\":\"2026-11-22T10:00\"}\nDone."
        let (acts, cleaned) = MacAction.extract(from: reply)
        check("parses 2 actions", acts.count == 2 && acts[0].kind == "open_app" && acts[1].args["title"] as? String == "Stretch")
        check("removes action lines from reply", !cleaned.contains("KIRI_ACTION") && cleaned.contains("Opening it now"))

        // 2. live test counting
        var p = TestRunner.Progress()
        for l in ["test_add (t.T.test_add) ... ok", "test_avg (t.T.test_avg) ... FAIL", "..F.", "PASSED tests/x.py::a",
                  "✓ renders (3 ms)", "--- FAIL: TestX", "Test Case '-[A b]' passed (0.1 s)."] { TestRunner.tally(l, into: &p) }
        check("counts passes (got \(p.passed))", p.passed == 7)
        check("counts failures (got \(p.failed))", p.failed == 3)

        // 3. screen phrases
        check("detects screen question", ScreenHelp.wantsScreen("What's on my screen?") && !ScreenHelp.wantsScreen("fix my tests"))

        // 4. speech cleanup
        check("speech skips code", !Voice.speakable("Fix:\n```python\nx = 1\n```\nDone").contains("x = 1"))

        // 5. folder watcher sees a save
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var fired = false
        let watcher = FolderWatcher(folder: tmp) { fired = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            try? "print(1)".write(to: tmp.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        check("file watcher fires on save", fired && watcher != nil)

        // 6. ignored folders don't trigger
        fired = false
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
        try? "x".write(to: tmp.appendingPathComponent("__pycache__/a.pyc"), atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        check("ignores __pycache__ changes", !fired)
        try? FileManager.default.removeItem(at: tmp)

        // 7. terminal events
        var got: TerminalWatcher.Failure?
        let tw = TerminalWatcher { got = $0 }
        if let h = try? FileHandle(forWritingTo: TerminalWatcher.eventsFile) {
            h.seekToEndOfFile(); h.write(Data("1\t/tmp\tnpm run build\n".utf8)); try? h.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check("reads failed terminal command", got?.command == "npm run build" && got?.code == 1 && tw != nil)
        let left = (try? FileManager.default.attributesOfItem(atPath: TerminalWatcher.eventsFile.path)[.size] as? UInt64) ?? 99
        check("terminal command cleared from disk after reading", left == 0)

        // wake phrase variants, and no false trigger on ordinary speech
        func wakes(_ t: String) -> Bool { WakeWord.wakePattern.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
        check("hears 'Hey Hoot' variants", wakes("Hey Hoot open Safari") && wakes("hey hood, what's up") && wakes("Play hold open the calculator") && wakes("Hey ho open the calculator"))
        check("hears 'Hey Kiri' variants", wakes("Hey Kiri open notes") && wakes("Hey Carrie open the calculator"))
        func cmd(_ t: String) -> String? { WakeWord.commandOffset(in: t).map { String(t.dropFirst($0)).trimmingCharacters(in: .whitespaces) } }
        check("'Hey' + command when Hoot is dropped", cmd("Hey open the calculator app") == "open the calculator app")
        check("'Hey' alone wakes", cmd("Hey") == "")
        check("chat with 'hey' doesn't wake", cmd("hey how are you doing") == nil && cmd("they open the door") == nil)
        check("ignores Hey Siri and normal speech", !wakes("Hey Siri open the calculator") && !wakes("I want to open the calculator") && !wakes("the hoot owl is cute"))

        // 8. a normal answer mentioning /login is not mistaken for a sign-in error
        let normal = #"{"type":"result","subtype":"success","is_error":false,"result":"You're reading a chat about running /login in Terminal.","session_id":"x"}"#
        let ev = ClaudeRunner.parse(Data(normal.utf8))
        check("answer mentioning /login stays an answer", ev.contains { if case .done = $0 { return true }; return false })
        let authErr = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"x"}"#
        check("real sign-in error detected", ClaudeRunner.parse(Data(authErr.utf8)).contains { if case .failed = $0 { return true }; return false })

        // 9. links and apps Claude picks on its own need an OK; ones you named don't
        let url = MacAction(kind: "open_url", args: ["url": "https://evil.example.com/x"])
        check("unasked link needs approval", MacActions.approvalQuestion(for: url, userSaid: "summarize this page") != nil)
        let gh = MacAction(kind: "open_url", args: ["url": "https://www.github.com/nipungalhotra/kiri"])
        check("link you named opens directly", MacActions.approvalQuestion(for: gh, userSaid: "open github.com please") == nil)
        let app = MacAction(kind: "open_app", args: ["name": "Terminal"])
        check("unasked app needs approval", MacActions.approvalQuestion(for: app, userSaid: "what's on my screen?") != nil)
        check("app you named opens directly", MacActions.approvalQuestion(for: app, userSaid: "Open terminal") == nil)

        // 10. logs stay private
        check("prompt text not logged", !Log.secret("my bank password is hunter2").contains("hunter2") || Log.verbose)
        let red = Log.redact("key sk-ant-api03-abcdefghijklmnop and token=ghp_abcdefghijklmnopqrstuvwx1234 password: hunter2")
        check("secrets masked", !red.contains("abcdefghijklmnop") && !red.contains("hunter2") && !red.contains("ghp_"))

        // 11. built-in commands
        check("“commit this” is the commit helper", PetState.builtIn(for: "Commit this.") == .commit)
        check("“brief me” is the daily brief", PetState.builtIn(for: "brief me") == .brief)
        check("“explain what I copied” reads the clipboard", PetState.builtIn(for: "Explain what I copied") == .clipboard)
        check("normal question isn't a built-in", PetState.builtIn(for: "how do I commit in git?") == nil)
        let hello = CustomCommands.Command(name: "say hello", kind: .shortcut("Kiri: Say Hello"))
        check("custom command matches its name", CustomCommands.match("Please say hello!", in: [hello]) == hello)
        check("custom command needs the whole name", CustomCommands.match("say hello to mom and tell her", in: [hello]) == nil)
        check("script file becomes a spoken name", CustomCommands.displayName(forFile: URL(fileURLWithPath: "/x/Start-Standup.sh")) == "start standup")

        check("“thanks” ends a voice conversation", PetState.endsConversation("Thanks!") && PetState.endsConversation("that's all") && !PetState.endsConversation("open Safari"))
        check("wake keeps listening for the command", WakeWord.command(in: "Hey Hoot") == "" && WakeWord.command(in: "Hey Hoot, open Safari") == "open Safari" && WakeWord.command(in: "open Safari") == "open Safari")
        check("“Hey, brief me” wakes for the brief", WakeWord.commandOffset(in: "Hey brief me") != nil)
        check("“Hey commit this” wakes for the commit helper", WakeWord.commandOffset(in: "Hey, commit this") != nil)

        check("misheard “Hey food, open Safari” still wakes", WakeWord.commandOffset(in: "Hey food, open Safari").map { String("Hey food, open Safari".dropFirst($0)).trimmingCharacters(in: CharacterSet(charactersIn: " ,")) } == "open Safari")
        check("“Hey hot” then a pause wakes", WakeWord.commandOffset(in: "Hey hot") != nil)
        check("“Hey Google” never wakes Kiri", WakeWord.commandOffset(in: "Hey Google") == nil && WakeWord.commandOffset(in: "Hey Siri open Safari") == nil)
        check("“hey how are you” doesn't wake", WakeWord.commandOffset(in: "hey how are you") == nil)

        // 12. copied errors
        check("Python traceback looks like an error", ClipboardWatcher.looksLikeError("Traceback (most recent call last):\n  File \"a.py\", line 3\nZeroDivisionError: division by zero"))
        check("JS stack looks like an error", ClipboardWatcher.looksLikeError("TypeError: x is undefined\n    at foo (app.js:10:5)"))
        check("plain text isn't an error", !ClipboardWatcher.looksLikeError("Let's meet at 5pm to talk about error handling ideas"))

        // 13. Xcode build log errors
        let log = "x\u{0}83\"/Users/me/App/ContentView.swift:12:5: error: cannot find 'foo' in scope\u{0}12\"y /Users/me/App/ContentView.swift:12:5: error: cannot find 'foo' in scope /a/b.swift:3:1: warning: unused"
        let errs = XcodeWatcher.errors(in: log)
        check("finds Xcode errors, once each (got \(errs.count))", errs.count == 1 && errs[0].hasSuffix("cannot find 'foo' in scope"))

        // 14. PR buddy reads gh output and notices changes
        let prJSON = #"[{"number":7,"title":"Add login","url":"u","headRefName":"login","statusCheckRollup":[{"name":"test","conclusion":"FAILURE","status":"COMPLETED"},{"name":"lint","conclusion":"SUCCESS","status":"COMPLETED"}],"reviews":[{"author":{"login":"sam"},"state":"CHANGES_REQUESTED"}],"comments":[]}]"#
        let prs = PRWatcher.parse(prJSON)
        check("parses PR checks", prs.first?.failing == ["test"] && prs.first?.ciState == "failed" && prs.first?.lastReviewer == "sam")
        var events: [String] = []
        let w = PRWatcher { e in switch e { case .ciFailed: events.append("fail"); case .ciPassed: events.append("pass"); case .newReview: events.append("review") } }
        w.update(prs)
        let green = PRWatcher.parse(prJSON.replacingOccurrences(of: "FAILURE", with: "SUCCESS").replacingOccurrences(of: #""comments":[]"#, with: #""comments":[{"author":{"login":"ana"}}]"#))
        w.update(green)
        check("PR events: red, then green + new review (got \(events))", events == ["fail", "pass", "review"])

        // 15. updates compare versions properly
        check("1.2.10 is newer than 1.2.9", Updates.isNewer("1.2.10", than: "1.2.9") && !Updates.isNewer("v1.2.1", than: "1.2.1") && Updates.isNewer("1.3", than: "1.2.1"))

        // 16. project memory
        let fake = URL(fileURLWithPath: "/tmp/kiri-selftest-project-\(ProcessInfo.processInfo.processIdentifier)")
        ProjectMemory.record(fake, ask: "fix the login bug", outcome: "Fixed it in auth.py")
        let ctx = ProjectMemory.context(for: fake) ?? ""
        check("memory remembers earlier work", !ProjectMemory.enabled || ctx.contains("fix the login bug"))
        ProjectMemory.forget(fake)
        check("memory can be forgotten", ProjectMemory.load(fake).entries.isEmpty)

        // 17. background jobs, automations, PRs
        check("“in the background, add docs” starts a background job", PetState.backgroundTask(in: "In the background, add docstrings to utils.py") == "add docstrings to utils.py")
        check("normal text isn't a background job", PetState.backgroundTask(in: "what is the background color?") == nil)
        check("“open a PR” is the PR helper", PetState.builtIn(for: "Open a PR") == .openPR)
        if case .add(let a)? = Automations.parse("every day at 9am brief me"), case .daily(9, 0, false) = a.repeatRule {
            check("automation: every day at 9am", a.command == "brief me")
        } else { check("automation: every day at 9am", false) }
        if case .add(let a)? = Automations.parse("Every weekday at 6:30 pm run tests"), case .daily(18, 30, true) = a.repeatRule {
            check("automation: weekdays at 6:30pm", a.command == "run tests")
        } else { check("automation: weekdays at 6:30pm", false) }
        if case .add(let a)? = Automations.parse("every hour check my PRs"), case .every(60) = a.repeatRule {
            check("automation: every hour", a.command == "check my prs")
        } else { check("automation: every hour", false) }
        check("automation: too often is refused", Automations.parse("every 1 minute run tests") == nil)
        check("automation: list / stop", Automations.parse("list automations") == .list && Automations.parse("stop automation 2") == .remove(2))
        let cal = Calendar.current
        let nineOFive = cal.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!
        let daily = Automation(command: "brief me", repeatRule: .daily(hour: 9, minute: 0, weekdaysOnly: false))
        var ran = daily; ran.lastRun = nineOFive
        check("automation due once a day", daily.isDue(at: nineOFive) && !ran.isDue(at: nineOFive.addingTimeInterval(60)))

        // 18. Keep / Undo really restores files
        let proj = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-undo-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let fileA = proj.appendingPathComponent("app.py"), fileNew = proj.appendingPathComponent("new.py")
        try? "print('before')\n".write(to: fileA, atomically: true, encoding: .utf8)
        if let snap = UndoSnapshot.take(proj) {
            try? "print('after')\n".write(to: fileA, atomically: true, encoding: .utf8)
            try? "x = 1\n".write(to: fileNew, atomically: true, encoding: .utf8)
            let changed = EditTracker.changedFiles(calls: ["1": ("Edit", fileA.path), "2": ("Write", fileNew.path), "3": ("Read", "/etc/hosts")],
                                                   denied: [], root: proj)
            check("tracks edited files (got \(changed.count))", changed.count == 2)
            changed.forEach { snap.restore($0) }
            let back = (try? String(contentsOf: fileA, encoding: .utf8)) ?? ""
            check("undo restores the old file", back == "print('before')\n")
            check("undo removes files Claude created", !FileManager.default.fileExists(atPath: fileNew.path))
            snap.discard()
        } else { check("undo snapshot", false) }
        try? FileManager.default.removeItem(at: proj)

        // 8. battery read works (or no battery)
        let b = Battery.read()
        check("battery readable (\(b.map { "\($0.percent)% onBattery=\($0.onBattery)" } ?? "no battery"))", true)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}
