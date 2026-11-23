import SwiftUI

/// A Claude job that runs on its own while you keep chatting ("in the background, add docstrings to utils.py").
/// At most two at a time. Each has its own Claude session and its own Keep / Undo review.
@MainActor
final class BackgroundTask: ObservableObject, Identifiable {
    enum Status { case starting, running, done, failed, stopped }
    let id = UUID()
    let title: String
    let started = Date()
    @Published var status: Status = .starting
    @Published var activity = "Getting ready…"
    let runner = ClaudeRunner()
    var calls: [String: (name: String, detail: String)] = [:]
    var denied: [(name: String, detail: String)] = []
    var snapshot: UndoSnapshot?

    init(title: String) { self.title = title }
    var isActive: Bool { status == .starting || status == .running }
}

extension PetState {
    static let maxBackground = 2

    /// "in the background, …" / "background: …" / "bg: …" → the task text, or nil.
    nonisolated static func backgroundTask(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["in the background,", "in the background:", "in the background", "in background,", "in background",
                  "background task:", "background:", "bg:"] where t.lowercased().hasPrefix(p) {
            let rest = String(t.dropFirst(p.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,:").union(.whitespaces))
            return rest.count >= 3 ? rest : nil
        }
        return nil
    }

    func startBackground(_ prompt: String) {
        guard backgroundTasks.filter(\.isActive).count < Self.maxBackground else {
            say("I'm already doing \(Self.maxBackground) background jobs. Let one finish first ⏳", for: 5)
            return
        }
        let dir = projectURL ?? Self.workspaceDir
        let task = BackgroundTask(title: String(prompt.prefix(60)))
        backgroundTasks.append(task)
        PetSignals.shared.backgroundCount = backgroundTasks.filter(\.isActive).count
        note("⏳ Started in the background: “\(task.title)”")
        say("On it in the background ⏳ Keep chatting!", for: 4)
        let edits = allowEdits
        withUndoSnapshot(for: dir, edits: edits) { [weak self] snap in
            guard let self else { return }
            task.snapshot = snap
            task.status = .running
            let full = prompt + "\n\n(This is a background task: work on your own, don't ask questions, and finish with a 1-2 sentence summary.)"
            task.runner.send(prompt: full, cwd: dir, sessionID: nil, allowEdits: edits) { [weak self, weak task] e in
                guard let self, let task else { return }
                self.handleBackground(e, task: task, root: dir)
            }
        }
    }

    private func handleBackground(_ e: ClaudeEvent, task: BackgroundTask, root: URL) {
        switch e {
        case .tool(let what): task.activity = what
        case .toolCall(let id, let name, let detail): task.calls[id] = (name, detail)
        case .denied(let id, let tool): task.denied.append(task.calls[id] ?? (tool, ""))
        case .done(let result, let isError, _):
            finishBackground(task, ok: !isError, text: MacAction.extract(from: result ?? "").cleaned, root: root)
        case .failed(let why):
            finishBackground(task, ok: false, text: why, root: root)
        default: break
        }
    }

    private func finishBackground(_ task: BackgroundTask, ok: Bool, text: String, root: URL) {
        guard task.isActive else { return }
        task.status = ok ? .done : .failed
        PetSignals.shared.backgroundCount = backgroundTasks.filter(\.isActive).count
        let short = text.isEmpty ? (ok ? "Done." : "It didn't work.") : text
        var line = (ok ? "✅" : "⚠️") + " Background: “\(task.title)” — \(short)"
        if !task.denied.isEmpty { line += "\n(It needed permission for \(task.denied.count) step\(task.denied.count == 1 ? "" : "s"). Ask me in the chat to do those.)" }
        messages.append(ChatMessage(role: .kiri, text: line))
        ProjectMemory.record(projectURL, ask: task.title, outcome: short)
        let files = EditTracker.changedFiles(calls: task.calls, denied: task.denied, root: root)
        if !busy { say(ok ? "Background job done ✅ \(task.title.prefix(40))" : "A background job had trouble ⚠️", for: 6) }
        if ok && !busy { feel(.happy, for: 2) }
        if speakReplies && !quiet && !busy { Voice.shared.speak(ok ? "Your background job is done." : "A background job had trouble.") }
        offerReview(title: task.title, files: files, snapshot: task.snapshot)
        // forget finished tasks after a while
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.backgroundTasks.removeAll { $0.id == task.id && !$0.isActive }
        }
    }

    func stopBackground(_ task: BackgroundTask) {
        task.runner.stop()
        task.status = .stopped
        PetSignals.shared.backgroundCount = backgroundTasks.filter(\.isActive).count
        note("⏹ Stopped “\(task.title)”.")
        let files = EditTracker.changedFiles(calls: task.calls, denied: task.denied, root: task.snapshot?.root ?? Self.workspaceDir)
        offerReview(title: task.title, files: files, snapshot: task.snapshot)
        backgroundTasks.removeAll { $0.id == task.id }
    }
}

/// Running background jobs, shown above the chat box.
struct BackgroundList: View {
    @ObservedObject var state: PetState

    var body: some View {
        let active = state.backgroundTasks.filter(\.isActive)
        if !active.isEmpty {
            VStack(spacing: 4) {
                ForEach(active) { BackgroundRow(task: $0, state: state) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

struct BackgroundRow: View {
    @ObservedObject var task: BackgroundTask
    let state: PetState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let secs = Int(Date().timeIntervalSince(task.started))
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                VStack(alignment: .leading, spacing: 0) {
                    Text(task.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(task.activity).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(String(format: "%d:%02d", secs / 60, secs % 60)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button { state.stopBackground(task) } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless).help("Stop this background job")
            }
        }
    }
}
