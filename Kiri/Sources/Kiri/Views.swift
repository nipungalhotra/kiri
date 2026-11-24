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
            if !state.reviews.isEmpty && !state.chatOpen {
                VStack(spacing: 6) {
                    Text(state.bubble ?? "Keep these changes?").font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)).multilineTextAlignment(.center).lineLimit(3)
                    HStack(spacing: 6) {
                        Button("Keep") { state.keepChanges() }.buttonStyle(.borderedProminent).tint(.green)
                        Button { state.undoChanges() } label: { Text("Undo").foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)) }.buttonStyle(.bordered)
                        Button { state.compareChanges() } label: { Image(systemName: "rectangle.split.2x1").foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)) }
                            .buttonStyle(.bordered).help("Compare before and after")
                    }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: 200)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
                .padding(.bottom, 4)
            } else if let text = state.bubble, !state.chatOpen || state.offerFix {
                SpeechBubble(text: text, showFix: state.offerFix, fixLabel: state.fixLabel,
                             onFix: { state.fixTests() }, onDismiss: { state.dismissFix() })
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
            KiriCharacter(mood: state.mood, leaves: state.leaves, style: state.style)
                .background(HootHalo(state: state).offset(y: 8))
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
    var fixLabel = "Fix it"
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
                    Button(fixLabel, action: onFix).buttonStyle(.borderedProminent).tint(.teal)
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

/// Hoot's colours for the chat window (purple, like the owl), in light and dark mode.
enum HootTheme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let purple = Color(nsColor: rgb(0x8B5CF6))
    static let deep = Color(nsColor: rgb(0x6D28D9))
    static let top = dynamic(rgb(0xFBF9FF), rgb(0x241D36))
    static let bottom = dynamic(rgb(0xF1EBFC), rgb(0x18131F))
    static let card = dynamic(rgb(0xFFFFFF), rgb(0x2F2745))
    static let chip = dynamic(rgb(0x8B5CF6, 0.10), rgb(0xFFFFFF, 0.08))
    static let line = dynamic(rgb(0x6D28D9, 0.12), rgb(0xFFFFFF, 0.08))
    static let field = dynamic(rgb(0xFFFFFF), rgb(0x0F0B16, 0.55))
    static let userBubble = LinearGradient(colors: [Color(nsColor: rgb(0x9F7AEA)), Color(nsColor: rgb(0x7C3AED))], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A small round owl face used as Hoot's avatar.
struct HootAvatar: View {
    var size: CGFloat = 26
    var body: some View {
        Text("🦉").font(.system(size: size * 0.6))
            .frame(width: size, height: size)
            .background(Circle().fill(HootTheme.userBubble))
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }
}

/// A round icon button / toggle in the chat toolbar.
struct ChipButton: View {
    let icon: String
    var on = false
    var label: String? = nil
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if let label { Text(label).font(.system(size: 11, weight: .medium)) }
            }
            .padding(.horizontal, label == nil ? 0 : 9)
            .frame(minWidth: 26, minHeight: 26)
            .foregroundStyle(on ? Color.white : HootTheme.purple)
            .background(Capsule().fill(on ? AnyShapeStyle(HootTheme.userBubble) : AnyShapeStyle(HootTheme.chip)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ChatView: View {
    @ObservedObject var state: PetState
    @State private var draft = ""
    @ObservedObject private var voice = VoiceInput.shared
    @FocusState private var focused: Bool

    private let examples = ["Explain this project to me", "Find bugs in my code", "What's on my screen?", "Remind me to stretch in 1 hour"]

    private var status: String {
        if voice.listening { return "Listening…" }
        if state.busy { return "Working…" }
        if state.testing { return "Running tests…" }
        return state.projectURL.map { "In \($0.lastPathComponent)" } ?? "Ready to help"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HootTheme.line.frame(height: 1)
            messageList
            if let activity = state.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(HootTheme.purple)
                    Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            if !state.reviews.isEmpty {
                ReviewBar(state: state).padding(.horizontal, 14).padding(.vertical, 6)
            }
            BackgroundList(state: state)
            inputRow
        }
        .background(LinearGradient(colors: [HootTheme.top, HootTheme.bottom], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(HootTheme.line))
        .shadow(color: HootTheme.deep.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 10).padding(.top, 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HootAvatar(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hoot").font(.system(size: 15, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle().fill(voice.listening ? Color.red : (state.busy ? Color.orange : Color.green)).frame(width: 6, height: 6)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { state.chooseProject() } label: {
                    Label(state.projectURL?.lastPathComponent ?? "Choose project", systemImage: "folder.fill")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(HootTheme.purple)
                        .background(Capsule().fill(HootTheme.chip))
                }
                .buttonStyle(.plain)
                .help(state.projectURL?.path ?? "Pick the project Kiri works in")
                Button { state.chatOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(HootTheme.chip))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc closes the chat
                .help("Close chat")
            }
            HStack(spacing: 6) {
                ChipButton(icon: "play.fill", label: "Tests", help: state.testPlan.map { "Runs: \($0.label)" } ?? "No tests found in this project") { state.runTests() }
                    .disabled(state.testing || state.projectURL == nil)
                ChipButton(icon: "pencil", on: state.allowEdits, label: state.allowEdits ? "Can edit" : "Read only",
                           help: "Off: Kiri can only read and explain. On: Kiri can change files in this project.") { state.allowEdits.toggle() }
                ChipButton(icon: state.watchTests ? "eye.fill" : "eye.slash", on: state.watchTests,
                           help: state.watchTests ? "Watching: tests re-run when you save a file" : "Re-run tests automatically when you save") { state.watchTests.toggle() }
                    .disabled(state.projectURL == nil)
                ChipButton(icon: "camera.viewfinder", help: "What's on my screen?") { state.askAboutScreen() }
                    .disabled(state.busy)
                ChipButton(icon: state.speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill", on: state.speakReplies,
                           help: state.speakReplies ? "Kiri reads replies out loud (click to mute)" : "Muted (click to hear replies)") { state.speakReplies.toggle() }
                Spacer()
                ChipButton(icon: "square.and.pencil", help: "New chat") { state.newChat() }
                    .disabled(state.messages.isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.messages.isEmpty { emptyState }
                    ForEach(state.messages) { MessageRow(message: $0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            .onChange(of: state.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hi! What are we working on? 🦉")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Say “Hey Hoot” or press ⌥Space and just talk. After I answer, I keep listening, so no need to say my name again.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { ex in
                Button { state.send(ex) } label: {
                    Text(ex).font(.system(size: 12)).foregroundStyle(HootTheme.purple)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(HootTheme.chip))
                }
                .buttonStyle(.plain)
                .disabled(state.busy)
            }
        }
        .padding(.vertical, 4)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { state.listen() } label: {
                Image(systemName: voice.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(voice.listening ? Color.white : HootTheme.purple)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(voice.listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(HootTheme.chip)))
                    .symbolEffect(.pulse, isActive: voice.listening)
            }
            .buttonStyle(.plain)
            .help(voice.listening ? "Listening… click to send now" : "Talk to Kiri (or press ⌥Space)")
            TextField(voice.listening ? "Listening… just talk" : "Message Hoot…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($focused)
                .focusEffectDisabled()
                .padding(.vertical, 6)
                .onSubmit(send)
                .onChange(of: voice.transcript) { _, words in if voice.listening { draft = words } }
                .onChange(of: voice.listening) { _, on in if !on { draft = "" } }
                // Enter sends (also after Wispr Flow dictation); Shift+Enter adds a new line.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                state.send("in the background: " + text)
            } label: {
                Image(systemName: "hourglass").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(empty ? Color.secondary.opacity(0.5) : HootTheme.purple)
                    .frame(width: 30, height: 30)
            }
                .buttonStyle(.plain)
                .disabled(empty)
                .help("Do this in the background while we keep chatting")
            if state.busy {
                Button { state.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain).help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(empty ? AnyShapeStyle(Color.secondary.opacity(0.3)) : AnyShapeStyle(HootTheme.userBubble)))
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HootTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(focused ? HootTheme.purple.opacity(0.5) : HootTheme.line))
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if state.busy && PetState.backgroundTask(in: text) == nil && Automations.parse(text) == nil { return }
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
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
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16, style: .continuous)
                        .fill(HootTheme.userBubble))
                    .shadow(color: HootTheme.deep.opacity(0.2), radius: 4, y: 2)
                    .textSelection(.enabled)
            }
        case .kiri:
            HStack(alignment: .top, spacing: 6) {
                HootAvatar(size: 24)
                bubbleContent
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .fill(HootTheme.card))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .stroke(HootTheme.line))
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
