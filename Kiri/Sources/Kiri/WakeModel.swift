import Foundation
import Speech

/// Teaches Apple's on-device recognizer the words "Hey Hoot".
/// Out of the box it doesn't know "Hoot" and writes "Play", "Hey ho", or nothing at all.
/// A small custom language model (built once on this Mac, kept in Application Support)
/// makes it expect "Hey Hoot" and the commands people say after it. Nothing leaves the Mac.
@MainActor
enum WakeModel {
    /// Bump when the phrases change, so the model is rebuilt.
    static let version = "3"
    private(set) static var configuration: SFSpeechLanguageModel.Configuration?
    private static var preparing = false

    static let commands = [
        "open Safari", "open Chrome", "open Mail", "open Terminal", "open Xcode", "open Music", "open Spotify",
        "what time is it", "what's the date", "what's on my screen", "volume up", "volume down", "mute", "unmute",
        "play", "pause", "next song", "previous song", "set a timer for five minutes", "minimise this", "full screen",
        "move this to the left", "move this to the right", "join my meeting", "battery", "good morning",
        "fix this error", "explain this", "run the tests", "commit my changes", "daily brief", "plan my day",
        "remind me in ten minutes", "stop", "wait", "never mind", "thank you", "how are you",
    ]

    /// Build (first time only) and load the model for `locale`. Safe to call repeatedly.
    static func prepare(for locale: Locale, then done: @escaping @MainActor () -> Void) {
        guard configuration == nil, !preparing else { return }
        preparing = true
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiri/WakeModel", isDirectory: true)
        let tag = "\(locale.identifier)-v\(version)"
        let data = dir.appendingPathComponent("hoot-\(tag).bin")
        let config = SFSpeechLanguageModel.Configuration(languageModel: dir.appendingPathComponent("lm-\(tag)"))
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: data.path) {
                    try await build(locale: locale).export(to: data)
                }
                try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: data, clientIdentifier: "app.kiri.owl", configuration: config)
                configuration = config
                Log.write("wake: custom model ready (\(tag))")
                done()
            } catch {
                Log.write("wake: custom model failed: \(error.localizedDescription)")
            }
            preparing = false
        }
    }

    private static func build(locale: Locale) -> SFCustomLanguageModelData {
        let d = SFCustomLanguageModelData(locale: locale, identifier: "app.kiri.owl.wake", version: version)
        d.insert(phraseCount: .init(phrase: "Hey Hoot", count: 3000))
        d.insert(phraseCount: .init(phrase: "Hoot", count: 800))
        d.insert(phraseCount: .init(phrase: "Hey Hoot stop", count: 300))
        d.insert(phraseCount: .init(phrase: "Hoot stop", count: 300))
        for c in commands {
            d.insert(phraseCount: .init(phrase: "Hey Hoot \(c)", count: 120))
            d.insert(phraseCount: .init(phrase: "Hey Hoot, \(c)", count: 60))
        }
        return d
    }
}
