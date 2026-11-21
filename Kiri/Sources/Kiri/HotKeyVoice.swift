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
        u.voice = Self.chosenVoice
        u.rate = 0.5
        u.pitchMultiplier = 1.12
        synth.speak(u)
        Log.write("speaking \(spoken.count) chars")
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Names of female macOS voices (many report no gender, so we also go by name).
    static let femaleNames: Set<String> = ["Samantha", "Ava", "Zoe", "Allison", "Susan", "Victoria", "Karen", "Moira", "Tessa",
                                           "Fiona", "Kate", "Serena", "Isha", "Veena", "Lekha", "Nicky", "Joelle", "Catherine",
                                           "Flo", "Sandy", "Shelley", "Kathy", "Siri Female"]

    static func isFemale(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.gender == .female || femaleNames.contains(v.name) || femaleNames.contains { v.name.hasPrefix($0 + " ") }
    }

    /// Installed female English voices, best quality first (for the 🦉 menu).
    static var femaleVoices: [AVSpeechSynthesisVoice] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && isFemale($0) }
            .sorted { ($0.quality.rawValue, $0.language == "en-IN" ? 1 : 0) > ($1.quality.rawValue, $1.language == "en-IN" ? 1 : 0) }
            .filter { seen.insert($0.name + $0.language).inserted }
    }

    /// The voice the user picked in the menu, else the best female voice (Samantha if nothing better).
    static var chosenVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "voiceID"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return femaleVoices.first { $0.quality != .default }
            ?? femaleVoices.first { $0.name == "Samantha" }
            ?? femaleVoices.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func choose(_ v: AVSpeechSynthesisVoice) {
        UserDefaults.standard.set(v.identifier, forKey: "voiceID")
        shared.speak("Hi! I'm Hoot. This is how I sound now.")
    }

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
