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
    /// "Test Hey Hoot": until this time, show what the recognizer hears (on screen only, never logged).
    var testUntil = Date.distantPast
    var onTestHeard: ((String) -> Void)?

    private(set) var enabled = false
    /// The mic is on and a recognition task is running.
    private var running = false
    private let engine = AVAudioEngine()
    /// The audio tap feeds whichever request is current, so a new task can take over with no gap.
    private let feed = Feed()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped for every new task, so late callbacks from an old (cancelled) task are ignored.
    private var generation = 0
    private var watchdog: Timer?
    private var startedAt = Date()
    private var lastHeardAt = Date.distantPast
    /// When "Hey Hoot" was heard (we then keep listening for the command in the same task).
    private var wokeAt: Date?
    /// Characters into the transcript where the command (after "Hey Hoot") begins.
    private var commandStart: Int?
    private var transcript = ""
    private var silence: DispatchWorkItem?

    /// Audio-thread-safe holder for the current request.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var req: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
        func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = req; lock.unlock(); r?.append(b) }
    }

    private lazy var recognizer: SFSpeechRecognizer? = {
        for id in ["en-IN", Locale.current.identifier, "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }()

    /// How "Hey Hoot" / "Hey Kiri" come out of Apple's on-device recognizer (measured: e.g. "Play hold",
    /// "Hey ho", "Hey Carrie"). "Hey Siri" is deliberately NOT accepted, so Kiri never competes with Siri.
    static let wakePattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey|hay|hi|hello|ok|okay|play)[\s,]+(?:hoot|hoots|hooted|hood|hut|hoo|ho|who|whoot|hold|hook|hoof|hoop|hot|hurt|huh|foot|food|good|wood|root|boot|hu|hoe|hoots?)|(?:hey|hay|hi|ok|okay)[\s,]+(?:kiri|keri|kerry|carrie|cary|kiry|kiree))\b"#,
        options: [.caseInsensitive])

    func setEnabled(_ on: Bool) {
        enabled = on
        watchdog?.invalidate()
        if on {
            // Check a few times a second: pause while speaking/listening, refresh the task before Apple's ~1 min limit.
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
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

    /// While Hoot is talking the mic stays on, so you can interrupt with "Hey Hoot…" or "Hoot, stop".
    /// (Only the exact wake phrase counts then, so Hoot's own voice can't wake it.)
    private var shouldPause: Bool {
        VoiceInput.shared.listening || (isBusy() && !Voice.shared.isSpeaking) || Date() < cooldownUntil
    }
    private var wasSpeaking = false
    /// "Hoot, stop" / "stop, Hoot" while Hoot is talking.
    static let stopPattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey[\s,]+)?(?:hoot|hood|hut|kiri)[\s,]+(?:stop|wait|quiet|enough|shush|shut up)|(?:stop|quiet|enough|wait)[\s,]+(?:hoot|hood|kiri))\b"#,
        options: [.caseInsensitive])
    /// Fires when you talk over Hoot ("Hoot, stop").
    var onInterrupt: (() -> Void)?

    private func tick() {
        guard enabled else { return }
        if shouldPause { if running { stop() }; return }
        if !running { start(); return }
        let speaking = Voice.shared.isSpeaking
        if wasSpeaking && !speaking && commandStart == nil { wasSpeaking = false; newTask(); return }   // drop Hoot's own words
        wasSpeaking = speaking
        guard commandStart == nil else { return }
        // Apple limits one task to about a minute. Swap in a fresh one during a quiet moment
        // (never in the middle of "Hey Hoot"), or at 55 s at the latest.
        let age = Date().timeIntervalSince(startedAt)
        if (age > 40 && Date().timeIntervalSince(lastHeardAt) > 1.5) || age > 55 { newTask() }
    }

    private func start() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else { Log.write("wake: recognizer unavailable"); return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { Log.write("wake: no speech permission"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { Log.write("wake: no mic permission"); return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in feed.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); Log.write("wake: mic start failed: \(error.localizedDescription)"); return }
        running = true
        Log.write("wake: listening for Hey Hoot (\(recognizer.locale.identifier))")
        newTask()
    }

    /// Start a fresh recognition task on the running mic, then retire the old one (no deaf gap).
    private func newTask() {
        guard running, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true      // never leaves the Mac
        req.taskHint = .dictation
        req.contextualStrings = ["Hey Hoot", "Hoot", "Hey Kiri", "Kiri"]   // teach it the unusual name
        let oldReq = request, oldTask = task
        generation += 1
        let gen = generation
        request = req
        feed.set(req)
        transcript = ""
        commandStart = nil
        wokeAt = nil
        silence?.cancel()
        startedAt = Date()
        task = recognizer.recognitionTask(with: req) { result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                let me = WakeWord.shared
                guard me.running, gen == me.generation else { return }   // an old task finishing: ignore
                if let text { me.heard(text) }
                if ended {
                    if me.commandStart != nil { me.finishWake() } else { me.newTask() }
                }
            }
        }
        oldReq?.endAudio()
        oldTask?.cancel()
    }

    private func stop() {
        guard running else { return }
        running = false
        generation += 1
        silence?.cancel()
        feed.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        commandStart = nil
        wokeAt = nil
    }

    /// The recognizer often drops "Hoot" and keeps only "Hey". Accept "Hey" + a command verb at the start
    /// of what was heard, or "Hey" alone followed by a pause. Plain chat ("hey, how are you") doesn't match.
    static let commandWords = #"open|launch|remind|run|fix|explain|show|find|organi[sz]e|turn|set|start|check|tell me|what'?s on|brief|daily brief|commit|good morning|what did i copy|achievements|say|plan my day|every|in the background|list automations|stop automation|create|push"#
    static let heyCommandPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:hey|hay|play)[\s,]+(?=(?:"# + commandWords + #")\b)"#,
        options: [.caseInsensitive])
    static let heyAlonePattern = try! NSRegularExpression(pattern: #"^\s*(?:hey|hay)[\s,.!]*$"#, options: [.caseInsensitive])
    /// Other assistants' names: never wake for these.
    static let otherAssistants = #"(?:siri|google|alexa|cortana|gemini)"#
    /// "Hey <any one word>, open Safari" — the recognizer often turns "Hoot" into a random word.
    static let heyAnyCommandPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:hey|hay|hi|hello|ok|okay)[\s,.!]+(?!"# + otherAssistants + #"\b)[\w']+[\s,.!]+(?=(?:"# + commandWords + #")\b)"#,
        options: [.caseInsensitive])
    /// "Hey <one word>" and then a pause — most likely "Hey Hoot" misheard; Kiri then listens for the command.
    static let shortHeyPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:hey|hay|hi|hello|ok|okay)[\s,.!]+(?!"# + otherAssistants + #"\b)[\w']+[\s,.!]*$"#,
        options: [.caseInsensitive])

    static func startsWithCommand(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:"# + commandWords + #")\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Where the command starts in `text` (after the wake phrase), or nil if there's no wake phrase.
    static func commandOffset(in text: String) -> Int? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for p in [wakePattern, heyCommandPattern, heyAnyCommandPattern, shortHeyPattern, heyAlonePattern] {
            if let m = p.matches(in: text, range: range).last, let r = Range(m.range, in: text) {
                return text.distance(from: text.startIndex, to: r.upperBound)
            }
        }
        return nil
    }

    private func heard(_ text: String) {
        if ProcessInfo.processInfo.environment["KIRI_WAKE_DEBUG"] != nil || CommandLine.arguments.contains("--wake-debug") { Log.write("wake heard: \(text.suffix(80))") }
        lastHeardAt = Date()
        transcript = text
        if Date() < testUntil { onTestHeard?(text) }
        if commandStart == nil {
            let speaking = Voice.shared.isSpeaking
            if speaking, Self.stopPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                Voice.shared.stop()
                Log.write("wake: interrupted (stop)")
                newTask()
                onInterrupt?()
                return
            }
            // while Hoot talks, only the exact wake phrase counts (so its own voice can't trigger it)
            let found: Int? = speaking ? Self.wakePattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last
                .flatMap { Range($0.range, in: text) }.map { text.distance(from: text.startIndex, to: $0.upperBound) } : Self.commandOffset(in: text)
            guard let offset = found else { return }
            if speaking { Voice.shared.stop(); Log.write("wake: interrupted Hoot") }
            commandStart = offset
            wokeAt = Date()
            Log.write("wake word heard")
            onHeardName?()                     // owl perks up right away
        }
        // Keep listening in this same task: wait for a short pause after the command,
        // or a bit longer if only "Hey Hoot" has been said so far.
        let rest = Self.command(in: transcript)
        silence?.cancel()
        let work = DispatchWorkItem { WakeWord.shared.finishWake() }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (rest.isEmpty ? 4.0 : 1.1), execute: work)
    }

    /// What was said after the wake phrase ("" if nothing yet).
    static func command(in text: String) -> String {
        let start: Int
        if let o = commandOffset(in: text) { start = o } else if startsWithCommand(text) { start = 0 } else { return "" }
        return String(text.dropFirst(start)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespacesAndNewlines))
    }

    private func finishWake() {
        guard commandStart != nil else { return }
        // The recognizer may rewrite earlier words (e.g. drop "Hey"), so find the wake phrase again;
        // if it vanished, everything heard is the command.
        guard Self.commandOffset(in: transcript) != nil || Self.startsWithCommand(transcript) else {
            Log.write("wake: false alarm, ignored")
            newTask()                         // just chat after a "hey": fresh task so the next "Hey" is at the start
            return
        }
        let rest = Self.command(in: transcript)
        if let w = wokeAt { Log.write(String(format: "wake: command after %.1fs (%d chars)", Date().timeIntervalSince(w), rest.count)) }
        stop()                                  // free the mic for the command / reply
        cooldownUntil = Date().addingTimeInterval(3)
        onWake?(rest)
    }
}
