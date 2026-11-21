import Foundation
import Speech

/// `Kiri --wake-probe <dir>`: transcribes p1…pN.aiff (with pN.txt = what was said) on-device in
/// Indian and US English and logs what the recognizer heard. Used to pick a wake phrase it catches.
enum WakeProbe {
    @MainActor
    static func run(_ dir: String) {
        Task.detached {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".aiff") }.sorted()) ?? []
            for loc in ["en-IN", "en-US"] {
                guard let r = SFSpeechRecognizer(locale: Locale(identifier: loc)) else { continue }
                for f in files {
                    let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: "\(dir)/\(f)"))
                    req.requiresOnDeviceRecognition = true
                    req.contextualStrings = ["Hoot", "Kiri", "Hey Hoot", "Hey Kiri"]
                    let heard: String = await withCheckedContinuation { c in
                        var done = false
                        r.recognitionTask(with: req) { res, err in
                            guard !done else { return }
                            if let res, res.isFinal { done = true; c.resume(returning: res.bestTranscription.formattedString) }
                            else if let err { done = true; c.resume(returning: "ERR \(err.localizedDescription)") }
                        }
                    }
                    let said = (try? String(contentsOfFile: "\(dir)/\(f.replacingOccurrences(of: ".aiff", with: ".txt"))", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? f
                    Log.write("probe \(loc) | said: \(said) | heard: \(heard)")
                }
            }
            Log.write("probe done")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }
}
