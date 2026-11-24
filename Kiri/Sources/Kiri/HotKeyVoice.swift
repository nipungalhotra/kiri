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

    override init() {
        super.init()
        synth.delegate = self
    }

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

    /// Add a sentence after whatever Hoot is already saying (for speaking a reply as it streams in).
    func enqueue(_ text: String) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        let u = AVSpeechUtterance(string: spoken)
        u.voice = Self.chosenVoice
        u.rate = 0.5
        u.pitchMultiplier = 1.12
        synth.speak(u)
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
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return femaleVoices.first { $0.quality == .premium }
            ?? english.first { $0.quality == .premium }
            ?? femaleVoices.first { $0.quality != .default }
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
        // emoji would be read out by name ("speaker high volume"), so drop them
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) && $0.value != 0xFE0F && $0.value != 0x200D }))
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 600 { s = String(s.prefix(600)) + "… the rest is on screen." }
        return s
    }
}

/// Lets the glowing ring pulse with each spoken word.
extension Voice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { VoiceHUD.shared.speaking = true; VoiceHUD.shared.lastWord = Date() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { VoiceHUD.shared.lastWord = Date() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Self.ended(s) }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Self.ended(s) }
    nonisolated private static func ended(_ s: AVSpeechSynthesizer) {
        // more sentences may be queued: only stop the ring when nothing is left to say
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if !Voice.shared.isSpeaking { VoiceHUD.shared.speaking = false } }
    }
}
