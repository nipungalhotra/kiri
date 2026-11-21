import AVFoundation
import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (default ⌥Space). Uses Carbon's RegisterEventHotKey, which
/// works from any app and needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered = false
    let label: String

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey, label: String = "⌥Space") {
        self.label = label
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.onPress?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4B495249), id: 1)  // 'KIRI'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        Log.write(registered ? "hotkey \(label) registered" : "hotkey \(label) NOT registered (status \(status)) — another app may use it")
    }
}

/// Reads replies out loud with the Mac's built-in voice.
@MainActor
final class Voice: NSObject {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        stop()
        let u = AVSpeechUtterance(string: spoken)
        u.voice = Self.bestVoice
        u.rate = 0.5
        u.pitchMultiplier = 1.08
        synth.speak(u)
        Log.write("speaking \(spoken.count) chars")
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Prefer an enhanced/premium English voice if the user has one installed.
    private static let bestVoice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Turn a markdown reply into something pleasant to hear: no code blocks, symbols or file noise.
    static func speakable(_ text: String) -> String {
        var parts = text.components(separatedBy: "```")
        for i in parts.indices where i % 2 == 1 { parts[i] = " (code shown on screen) " }
        var s = parts.joined()
        for token in ["**", "__", "`", "#", "> ", "- "] { s = s.replacingOccurrences(of: token, with: " ") }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 600 { s = String(s.prefix(600)) + "… the rest is on screen." }
        return s
    }
}
