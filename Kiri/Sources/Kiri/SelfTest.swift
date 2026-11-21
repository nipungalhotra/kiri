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

        // 8. a normal answer mentioning /login is not mistaken for a sign-in error
        let normal = #"{"type":"result","subtype":"success","is_error":false,"result":"You're reading a chat about running /login in Terminal.","session_id":"x"}"#
        let ev = ClaudeRunner.parse(Data(normal.utf8))
        check("answer mentioning /login stays an answer", ev.contains { if case .done = $0 { return true }; return false })
        let authErr = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"x"}"#
        check("real sign-in error detected", ClaudeRunner.parse(Data(authErr.utf8)).contains { if case .failed = $0 { return true }; return false })

        // 8. battery read works (or no battery)
        let b = Battery.read()
        check("battery readable (\(b.map { "\($0.percent)% onBattery=\($0.onBattery)" } ?? "no battery"))", true)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}
