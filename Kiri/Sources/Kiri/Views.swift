import AppKit
import SwiftUI

/// Everything inside the floating window: optional chat panel on top, Kiri at the bottom-right.
struct RootView: View {
    @ObservedObject var state: PetState
    let controller: PetWindowController

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if state.chatOpen {
                ChatView(state: state).frame(height: 430)
            }
            Spacer(minLength: 0)
            PetArea(state: state, controller: controller)
                .frame(width: PetWindowController.compact.width, height: PetWindowController.compact.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct PetArea: View {
    @ObservedObject var state: PetState
    let controller: PetWindowController

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            if let text = state.bubble, !state.chatOpen || state.offerFix {
                SpeechBubble(text: text, showFix: state.offerFix,
                             onFix: { state.fixTests() }, onDismiss: { state.dismissFix() })
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
            KiriCharacter(mood: state.mood, leaves: state.leaves, style: state.style)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in controller.dragChanged() }
                        .onEnded { _ in if !controller.dragEnded() { state.petTapped() } }
                )
                .contextMenu {
                    Button(state.chatOpen ? "Close chat" : "Open chat") { state.chatOpen.toggle() }
                    Button("Run tests") { state.runTests() }
                    Button("Choose project…") { state.chooseProject() }
                    Divider()
                    Menu("Character") {
                        ForEach(CharacterStyle.allCases) { s in
                            Button((s == state.style ? "✓ " : "") + s.title) { state.useStyle(s) }
                        }
                    }
                    Divider()
                    Button("Hide Kiri") { controller.hide() }
                    Button("Quit Kiri") { NSApp.terminate(nil) }
                }
                .help("Click to chat · drag to move · right-click for more")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state.bubble)
    }
}

struct SpeechBubble: View {
    let text: String
    var showFix = false
    var onFix: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if showFix {
                HStack(spacing: 6) {
                    Button("Fix it", action: onFix).buttonStyle(.borderedProminent).tint(.teal)
                    Button(action: onDismiss) { Text("Not now").foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white).frame(width: 10, height: 10)
                .rotationEffect(.degrees(45)).offset(y: 4)
        }
        .padding(.bottom, 4)
    }
}

// MARK: Chat

struct ChatView: View {
    @ObservedObject var state: PetState
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let examples = ["Explain this project to me", "Find bugs in my code", "What should I test next?"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let activity = state.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            inputRow
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 10).padding(.top, 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("🌱 Kiri").font(.headline)
                Spacer()
                Button { state.chooseProject() } label: {
                    Label(state.projectURL?.lastPathComponent ?? "Choose project", systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(state.projectURL?.path ?? "Pick the project Kiri works in")
                Button { state.chatOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close chat")
            }
            HStack(spacing: 10) {
                Button { state.runTests() } label: { Label("Run tests", systemImage: "play.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.testing || state.projectURL == nil)
                    .help(state.testPlan.map { "Runs: \($0.label)" } ?? "No tests found in this project")
                Toggle("Can edit files", isOn: $state.allowEdits)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Off: Kiri can only read and explain. On: Kiri can change files in this project.")
                Toggle(isOn: $state.speakReplies) { Image(systemName: state.speakReplies ? "speaker.wave.2.fill" : "speaker.slash") }
                    .toggleStyle(.button).controlSize(.small)
                    .help(state.speakReplies ? "Kiri reads replies out loud (click to mute)" : "Muted (click to hear replies)")
                Spacer()
                Button("New chat") { state.newChat() }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(state.messages.isEmpty)
            }
            .font(.caption)
        }
        .padding(12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.messages.isEmpty { emptyState }
                    ForEach(state.messages) { MessageRow(message: $0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: state.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask me anything about your code.")
                .font(.callout.weight(.semibold))
            Text("Tip: press ⌥Space in any app, then talk with Wispr Flow 🎙️")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { ex in
                Button(ex) { state.send(ex) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.busy)
            }
        }
        .padding(.vertical, 4)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Kiri… or speak with Wispr Flow", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                // Enter sends (also after Wispr Flow dictation); Shift+Enter adds a new line.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            if state.busy {
                Button { state.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.busy else { return }
        draft = ""
        state.send(text)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    /// Splits a reply into prose and ``` fenced code blocks.
    private var parts: [(isCode: Bool, text: String)] {
        let chunks = message.text.components(separatedBy: "```")
        return chunks.enumerated().compactMap { i, chunk in
            var text = chunk
            if i % 2 == 1, let nl = text.firstIndex(of: "\n") {
                // drop the language tag after the opening fence (```python)
                let tag = text[..<nl]
                if !tag.contains(" ") { text = String(text[text.index(after: nl)...]) }
            }
            let trimmed = text.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : (i % 2 == 1, trimmed)
        }
    }

    private func prose(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    Text(part.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
                } else {
                    Text(prose(part.text))
                }
            }
        }
        .textSelection(.enabled)
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(prose(message.text))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.teal))
                    .textSelection(.enabled)
            }
        case .kiri:
            HStack(alignment: .top, spacing: 6) {
                Text("🌱")
                bubbleContent
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)))
                Spacer(minLength: 20)
            }
        case .note:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }
}
