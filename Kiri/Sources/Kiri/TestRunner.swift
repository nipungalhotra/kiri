import Foundation

/// Finds and runs a project's tests.
enum TestRunner {
    struct Plan {
        let command: String
        let label: String
    }

    static func detect(in dir: URL) -> Plan? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        let top = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []

        if has("package.json"),
           let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any], scripts["test"] != nil {
            return Plan(command: "npm test --silent", label: "npm test")
        }
        if has("Package.swift") { return Plan(command: "swift test", label: "swift test") }
        if has("Cargo.toml") { return Plan(command: "cargo test", label: "cargo test") }
        if has("go.mod") { return Plan(command: "go test ./...", label: "go test") }

        let pyTests = top.contains { ($0.hasPrefix("test_") || $0.hasSuffix("_test.py")) && $0.hasSuffix(".py") }
        if pyTests || has("pytest.ini") || has("pyproject.toml") || has("setup.py") || has("tests") {
            return Plan(
                command: "if python3 -c 'import pytest' 2>/dev/null; then python3 -m pytest -q; else python3 -m unittest discover -v; fi",
                label: "python tests")
        }
        if has("Makefile"),
           let mk = try? String(contentsOf: dir.appendingPathComponent("Makefile"), encoding: .utf8),
           mk.hasPrefix("test:") || mk.contains("\ntest:") {
            return Plan(command: "make test", label: "make test")
        }
        return nil
    }

    /// Runs `plan` in `dir` through a login shell; calls back on the main queue with (passed, output).
    /// Running totals while tests run.
    struct Progress { var passed = 0; var failed = 0 }

    /// Counts passed/failed tests from one line of output, across common runners:
    /// unittest -v ("... ok"), pytest (-v "PASSED" or -q dots), jest ("✓"/"✕"), swift test, cargo, go -v.
    static func tally(_ line: String, into p: inout Progress) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasSuffix("... ok") || l.contains(" PASSED") || l.hasPrefix("PASSED ") || l.hasPrefix("✓") || l.hasPrefix("--- PASS")
            || (l.hasPrefix("Test Case") && l.contains(" passed")) || (l.hasPrefix("test ") && l.hasSuffix(" ... ok")) {
            p.passed += 1
        } else if l.hasSuffix("... FAIL") || l.hasSuffix("... ERROR") || l.contains(" FAILED") || l.hasPrefix("FAILED ") || l.hasPrefix("✕")
                    || l.hasPrefix("--- FAIL") || (l.hasPrefix("Test Case") && l.contains(" failed")) {
            p.failed += 1
        } else if !l.isEmpty, l.range(of: #"^[.FEsx]+(\s+\[\s*\d+%\])?$"#, options: .regularExpression) != nil {
            // pytest -q progress dots
            for ch in l { if ch == "." { p.passed += 1 } else if ch == "F" || ch == "E" { p.failed += 1 } }
        }
    }

    /// Runs `plan` in `dir`; streams live pass/fail counts to `progress`, then calls `completion(passed, output)`.
    /// Both callbacks arrive on the main queue.
    @discardableResult
    static func run(_ plan: Plan, in dir: URL, progress: ((Progress) -> Void)? = nil,
                    completion: @escaping (Bool, String) -> Void) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", plan.command]
        p.currentDirectoryURL = dir
        p.environment = ClaudeRunner.environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(false, "Couldn't run `\(plan.command)`: \(error.localizedDescription)") }
                return
            }
            var all = Data()
            var partial = ""
            var counts = Progress()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                all.append(chunk)
                partial += String(decoding: chunk, as: UTF8.self)
                var lines = partial.components(separatedBy: "\n")
                partial = lines.removeLast()
                let before = (counts.passed, counts.failed)
                for line in lines { tally(line, into: &counts) }
                if (counts.passed, counts.failed) != before, let progress {
                    let snapshot = counts
                    DispatchQueue.main.async { progress(snapshot) }
                }
            }
            p.waitUntilExit()
            let output = String(data: all, encoding: .utf8) ?? ""
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { completion(ok, output) }
        }
        return p
    }

    /// One short line that sums up a test run, e.g. "Ran 4 tests … FAILED (failures=1)".
    static func summary(of output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let keys = ["passed", "failed", "FAILED", "OK", "error", "Error", "Executed", "test result"]
        let hit = lines.last(where: { line in keys.contains { line.contains($0) } }) ?? lines.last ?? ""
        return String(hit.prefix(90))
    }
}
