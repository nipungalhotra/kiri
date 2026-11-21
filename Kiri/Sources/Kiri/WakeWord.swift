import AVFoundation
import Speech

/// Always-on "Hey Hoot" listener (on-device speech recognition).
///   "Hey Hoot, open Safari"  → sends "open Safari"
///   "Hey Hoot" … (pause)     → starts a normal voice command
/// It pauses itself while Kiri is speaking or already taking a command, so it never hears itself.
@MainActor
final class WakeWord {
    static let shared = WakeWord()

    /// Words after the wake phrase (may be empty: then the caller should listen for a command).
    var onWake: ((String) -> Void)?
    /// The wake phrase was just heard (owl can perk up).
    var onHeardName: (() -> Void)?

    private(set) var enabled = false
    private var running = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var watchdog: Timer?
    private var startedAt = Date()
    /// Characters into the transcript where the command (after "Hey Hoot") begins.
    private var commandStart: Int?
    private var transcript = ""
    private var silence: DispatchWorkItem?

    private lazy var recognizer: SFSpeechRecognizer? = {
        for id in ["en-IN", Locale.current.identifier, "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }()

    /// How "Hey Hoot" / "Hey Kiri" come out of Apple's on-device recognizer (measured: e.g. "Play hold",
    /// "Hey ho", "Hey Carrie"). "Hey Siri" is deliberately NOT accepted, so Kiri never competes with Siri.
    static let wakePattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey|hay|hi|hello|ok|okay|play)[\s,]+(?:hoot|hoots|hood|hut|hoo|ho|who|whoot|hold|hook|hoof)|(?:hey|hay|hi|ok|okay)[\s,]+(?:kiri|keri|kerry|carrie|cary|kiry|kiree))\b"#,
        options: [.caseInsensitive])

    func setEnabled(_ on: Bool) {
        enabled = on
        watchdog?.invalidate()
        if on {
            // Re-check once a second: pause while speaking/listening, restart tasks before Apple's ~1 min limit.
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { WakeWord.shared.tick() }
            }
            tick()
        } else {
            stop()
        }
        Log.write("wake word \(on ? "on" : "off")")
    }

    /// Extra pause condition from the app (e.g. "Kiri is busy answering").
    var isBusy: () -> Bool = { false }
    private var cooldownUntil = Date.distantPast

    private var shouldPause: Bool {
        VoiceInput.shared.listening || Voice.shared.isSpeaking || isBusy() || Date() < cooldownUntil
    }

    private func tick() {
        guard enabled else { return }
        if shouldPause { if running { stop() }; return }
        if !running { start(); return }
        // recycle the recognition task while idle (Apple limits a single task to about a minute)
        if commandStart == nil, Date().timeIntervalSince(startedAt) > 50 { stop(); start() }
    }

    private func start() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else { Log.write("wake: recognizer unavailable"); return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { Log.write("wake: no speech permission"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { Log.write("wake: no mic permission"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true      // never leaves the Mac
        req.contextualStrings = ["Hey Hoot", "Hoot", "Hey Kiri", "Kiri"]   // teach it the unusual name
        request = req
        transcript = ""
        commandStart = nil
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak req] buf, _ in req?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); Log.write("wake: mic start failed: \(error.localizedDescription)"); return }
        running = true
        Log.write("wake: listening for Hey Hoot (\(recognizer.locale.identifier))")
        startedAt = Date()
        task = recognizer.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                let me = WakeWord.shared
                guard me.running else { return }
                if let result { me.heard(result.bestTranscription.formattedString) }
                if error != nil || (result?.isFinal ?? false) { me.stop() }   // watchdog restarts it
            }
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    /// The recognizer often drops "Hoot" and keeps only "Hey". Accept "Hey" + a command verb at the start
    /// of what was heard, or "Hey" alone followed by a pause. Plain chat ("hey, how are you") doesn't match.
    static let heyCommandPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:hey|hay|play)[\s,]+(?=(?:open|launch|remind|run|fix|explain|show|find|organi[sz]e|turn|set|start|check|tell me|what'?s on)\b)"#,
        options: [.caseInsensitive])
    static let heyAlonePattern = try! NSRegularExpression(pattern: #"^\s*(?:hey|hay)[\s,.!]*$"#, options: [.caseInsensitive])

    static func startsWithCommand(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:open|launch|remind|run|fix|explain|show|find|organi[sz]e|turn|set|start|check|tell me|what'?s on)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Where the command starts in `text` (after the wake phrase), or nil if there's no wake phrase.
    static func commandOffset(in text: String) -> Int? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for p in [wakePattern, heyCommandPattern, heyAlonePattern] {
            if let m = p.matches(in: text, range: range).last, let r = Range(m.range, in: text) {
                return text.distance(from: text.startIndex, to: r.upperBound)
            }
        }
        return nil
    }

    private func heard(_ text: String) {
        if ProcessInfo.processInfo.environment["KIRI_WAKE_DEBUG"] != nil || CommandLine.arguments.contains("--wake-debug") { Log.write("wake heard: \(text.suffix(80))") }
        transcript = text
        if commandStart == nil {
            guard let offset = Self.commandOffset(in: text) else { return }
            commandStart = offset
            Log.write("wake word heard")
            onHeardName?()
        }
        // wait for a short pause after the last word, then hand over what followed the wake phrase
        silence?.cancel()
        let work = DispatchWorkItem { WakeWord.shared.finishWake() }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func finishWake() {
        guard commandStart != nil else { return }
        // The recognizer may rewrite earlier words (e.g. drop "Hey"), so find the wake phrase again;
        // if it vanished, everything heard is the command.
        let start: Int
        if let o = Self.commandOffset(in: transcript) {
            start = o
        } else if Self.startsWithCommand(transcript) {
            start = 0                         // "Hey" got rewritten away, but it's clearly a command
        } else {
            Log.write("wake: false alarm, ignored")
            stop()                            // just chat after a "hey": start fresh so the next "Hey" is at the start
            return
        }
        let rest = String(transcript.dropFirst(start)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespacesAndNewlines))
        stop()                                  // free the mic for the command / reply
        cooldownUntil = Date().addingTimeInterval(4)
        onWake?(rest)
    }
}
