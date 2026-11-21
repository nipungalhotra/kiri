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
    @discardableResult
    static func run(_ plan: Plan, in dir: URL, completion: @escaping (Bool, String) -> Void) -> Process {
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
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
