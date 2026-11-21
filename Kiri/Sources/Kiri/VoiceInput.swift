import AVFoundation
import Speech

/// Built-in voice commands: listens through the mic, shows the words live, and finishes by
/// itself when you stop talking. Uses on-device recognition when available (audio stays on the Mac).
@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    /// 0...1 microphone loudness, for the owl's sound waves.
    @Published private(set) var level: Float = 0

    /// Called with the final words (empty if nothing was heard).
    var onFinished: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: DispatchWorkItem?
    private var maxTimer: DispatchWorkItem?
    private var heardSomething = false

    /// Indian English first (better for Indian accents), then the Mac's language, then US English.
    private lazy var recognizer: SFSpeechRecognizer? = {
        for id in ["en-IN", Locale.current.identifier, "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable { return r }
        }
        return nil
    }()

    enum Problem: Error { case noSpeechPermission, noMicPermission, unavailable, audio(String) }

    func start() async throws {
        guard !listening else { return }
        guard await Self.speechAllowed() else { throw Problem.noSpeechPermission }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Problem.noMicPermission }
        guard let recognizer, recognizer.isAvailable else { throw Problem.unavailable }

        Voice.shared.stop()   // don't listen to ourselves
        transcript = ""
        heardSomething = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.contextualStrings = ["Hoot", "Kiri", "Wispr", "Claude"]
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
            let rms = Self.rms(buffer)
            DispatchQueue.main.async { VoiceInput.shared.level = rms }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw Problem.audio(error.localizedDescription) }

        listening = true
        Log.write("listening (\(recognizer.locale.identifier), onDevice=\(req.requiresOnDeviceRecognition))")
        task = recognizer.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                let me = VoiceInput.shared
                guard me.listening else { return }
                if let result {
                    me.transcript = result.bestTranscription.formattedString
                    if !me.transcript.isEmpty { me.heardSomething = true }
                    if result.isFinal { me.finish(send: true); return }
                    me.armSilenceTimer()
                }
                if error != nil { me.finish(send: true) }
            }
        }
        // Give up quietly if nothing is said; never listen longer than 30 s.
        armSilenceTimer(after: 6)
        let cap = DispatchWorkItem { VoiceInput.shared.finish(send: true) }
        maxTimer = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: cap)
    }

    /// Stop listening. `send == true` hands the words to `onFinished`.
    func finish(send: Bool) {
        guard listening else { return }
        listening = false
        silence?.cancel(); maxTimer?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("listening done: \(Log.secret(words, max: 120)) send=\(send)")
        if send { onFinished?(words) }
    }

    /// Finish ~1.3 s after the last word (longer before the first word).
    private func armSilenceTimer(after seconds: Double? = nil) {
        silence?.cancel()
        let wait = seconds ?? (heardSomething ? 1.3 : 6)
        let work = DispatchWorkItem { VoiceInput.shared.finish(send: true) }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, (sum / Float(n)).squareRoot() * 8)
    }
}
