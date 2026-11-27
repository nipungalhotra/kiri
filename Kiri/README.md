<p align="center">
  <img src="docs/icon.png" width="128" alt="Kiri app icon">
</p>

<h1 align="center">Kiri 🦉</h1>
<p align="center"><b>A desktop pet for macOS that actually codes.</b><br>
It runs your tests, gets sad when they fail, fixes the bug with Claude, and celebrates when they pass.</p>

<p align="center">
  <img src="docs/hoot-moods.gif" width="300" alt="Hoot the owl cycling through moods">
</p>

## What it does
- **Lives on your Mac:** Hoot the owl floats on your desktop or, on MacBooks with a notch, **lives in the notch** and expands when something happens.
- **Real coding help:** chat about your project, find bugs, and let it **fix failing tests**. Powered by [Claude Code](https://claude.com/claude-code).
- **Feelings:** idle → thinking → working (headphones) → **sad** when tests fail → **celebrating** when they pass → sleepy late at night. It blinks with real furry eyelids.
- **“Hey Hoot”:** say *“Hey Hoot, open Safari”* hands-free (always-on, on-device; pauses while Hoot talks; turn off in 🦉 → Voice).
- **Voice commands:** press **⌥Space in any app** and just talk. Hoot listens (on your Mac, Indian or US English), shows your words live, and **sends when you stop talking**. Replies are **read out loud in a female voice** (pick one in 🦉 → Voice).
- **Sees your screen:** press 📸 or ask *“what's on my screen?”* and Hoot explains what you're looking at.
- **Mac tasks:** *“Open Safari”*, *“Remind me to stretch at 5pm”*, *“Organize my Downloads”*, *“Turn on focus”*.
- **Watches in the background:** 👀 re-runs tests whenever you save, and an optional terminal hook lets Hoot notice failed commands and offer help.
- **Asks before risky things:** if Claude wants to run a command or edit a file it isn't allowed to, Kiri shows exactly what and lets you **Allow once** (⚠️ marks risky ones).
- **Live progress:** *“Running tests… 3 passed · 1 failed”*.
- **Worried when your battery is low** (unplugged, ≤20%) until you plug in. 🔋
- **Safe by default:** read-only until you flip **Can edit files**, and it can only run your test commands.
- **No surprise apps or links:** if Claude wants to open an app or website you didn't name yourself, Kiri asks first.
- **Expressive:** live eyes follow your mouse and react to moods, a quick “oh!” when surprised, and a beak that talks while Kiri speaks.
- **Light on your Mac:** 8–24 fps, GPU-drawn, and it pauses when hidden.

### New in 1.6 beta (Hoot hears its name)

- **"Hey Hoot" is heard much more reliably**: Kiri teaches the Mac's on-device speech recognizer the word "Hoot" with a small custom language model, built once on your Mac. Nothing leaves your Mac.
- **More ways to wake it**: if "Hoot" is misheard ("Hey, what time is it", "Hey Google, open Safari"), Hoot still wakes for real commands. "Hey Siri" never wakes it, and plain chat like "hey, how are you" doesn't either.
- **Spoken app names work**: *"minimise Claude desktop"* (often heard as "cloud") and *"minimise the Chrome window"* find the right app.

### New in 1.5.1 beta

- **Faster "Hey Hoot"**: background noise no longer drags out the wait. Say just "Hey Hoot" and Hoot is listening for your request within 4 seconds; say the whole request and it acts about a second after you stop.
- If speech or mic permission is missing, the log notes it once instead of filling up.

### New in 1.5 beta (Jarvis-style Hoot)
- **Instant Mac commands, no waiting for Claude:** *“volume up”*, *“set volume to 30”*, *“mute”*, *“minimise this”*, *“minimise the Safari window”*, *“full screen”*, *“move this to the left”*, *“play”*, *“next song”*, *“set a timer for 5 minutes”*, *“what time is it”*, *“battery”*, *“open Notes”*. Moving windows needs Accessibility permission.
- **Answers start right away:** Hoot says *“On it”* at once and speaks Claude's reply sentence by sentence as it arrives.
- **Interrupt Hoot:** say *“Hey Hoot…”* or *“Hoot, stop”* while it's talking.
- **Optional local model:** with [Ollama](https://ollama.com) and `ollama pull llama3.2:3b`, small talk and simple questions are answered on your Mac in about a second. Code still goes to Claude. 🦉 → Options → *How to Set Up the Local Model…*
- **Nicer voice:** 🦉 → Voice → *Get nicer voices…* explains how to download a Premium voice; Hoot picks it automatically.
- **Spoken heads-ups:** *“Your meeting starts in 5 minutes”* (say *“join the meeting”* to open the Zoom/Meet/Teams link), CI failures, failed tests or builds, low battery, finished background jobs. When Hoot asks *“Want me to fix it?”*, just say *“yes”*. Hoot stays silent during meetings and in Quiet Mode (🦉 → Options → *Speak Heads-Ups*).
- **Glowing voice ring:** ripples around Hoot while it listens, a circle of sound bars that pulses with each word while it talks, spinning arcs while it thinks, and a flash when it hears *“Hey Hoot”*. On Macs with a notch, live sound bars show there too. 🦉 → Options → *Glowing Ring When Talking*.
- **Knows you:** Hoot uses your name and a calm, dry-witted personality. Say *“call me …”*, *“remember that I like short answers”*, *“what do you remember about me”*, *“forget that …”*. Kept on your Mac and shared only with Claude as part of your chats.

### New in 1.4
- **Keep / Undo:** after Hoot changes code you get **Keep**, **Undo** (puts every file back, new files go to the Trash) and **Compare** (opens FileMerge).
- **Background jobs:** start a message with *“in the background, …”* or press ⏳. Up to two run while you keep chatting.
- **Automations:** *“every day at 9am brief me”*, *“every weekday at 6pm run tests”*, *“every hour check my PRs”*, *“list automations”*.
- **Open a PR:** *“open a PR”* pushes your branch and opens a pull request after you check the title and description (never pushes to main).
- **Mail in the daily brief:** unread count and latest senders from the Mail app (when Mail is open).
- **Livelier Hoot while working:** headphones, eyes reading the code, floating code, head bobbing, and a badge showing what it's doing and for how long.
- **Test “Hey Hoot”:** 🦉 → Voice shows what the mic hears, and wake detection is more forgiving.
- **Talk without repeating “Hey Hoot”:** after Hoot answers out loud it keeps listening for a follow-up. Stay quiet for a few seconds or say *“thanks”* to finish.
- **Faster, steadier wake word:** no more deaf moments every minute, and Hoot keeps listening for your command right after its name.
- **New chat window:** purple to match Hoot, in light and dark mode.

### New in 1.3
- **PR buddy:** watches your open GitHub pull requests (via `gh`). CI fails → Hoot gets sad and offers **Fix it**; a new review → **Explain**.
- **Commit helper:** say or type *“commit this”*. Claude writes the message from your diff, you edit/approve it, Kiri commits (never pushes).
- **Xcode error catcher:** when an Xcode build fails, Hoot reads the compiler errors and offers to fix them.
- **Clipboard helper:** copy an error and Hoot offers to explain it (or 🦉 → *Explain What I Copied*).
- **Project memory:** Hoot remembers what you worked on (only on your Mac) and greets you with *“Morning! Yesterday you were…”*.
- **Daily brief:** *“brief me”* → today's meetings, reminders due, GitHub notifications, failing CI and tests.
- **Focus coach:** a stretch-break nudge after 90 minutes of coding, and **Quiet Mode** (🤫) that keeps Hoot calm while you focus.
- **Screen tutor:** ask *“where do I click to …?”* and Hoot points at the button on your screen with a glowing arrow.
- **Your own commands:** drop a script into 🦉 → My Commands → *Open Commands Folder* (e.g. `start-standup.sh`) or name a Shortcut “Kiri: …”, then just say its name.
- **Hoot evolves:** earns 🤓 glasses (10 green test runs), 🎓 a cap (5 fixes) and 👑 a crown (10 green in a row). *“achievements”* shows progress.
- **Buddy pet:** 🦉 → Buddy Pet adds a second little character that minds the tests and banters with Hoot.
- **Setup check** on first launch (Claude installed and signed in, permissions) with one-click fixes, and **update notices** when a new release is out.

| Notch mode (MacBook Pro / Air with notch) | Desktop mode (every Mac) |
|---|---|
| <img src="docs/kiri-notch.png" width="420"> | <img src="docs/kiri-owl.png" width="420"> |

## Install
1. Download **`Kiri-1.6.dmg`** from Releases, open it, and drag **Kiri** into **Applications**.
2. First launch: **right-click Kiri → Open → Open** (it isn't notarized yet).
3. One-time Claude setup in Terminal:
   ```bash
   npm install -g @anthropic-ai/claude-code   # if you don't have `claude` yet
   claude --setting-sources project,local       # then type /login and sign in
   ```
4. Click **Allow** when macOS asks whether Kiri can read your project folder.

Requires **macOS 14+**, Apple Silicon or Intel.

## Use it
- **Press ⌥Space in any app** → Hoot puts on headphones and listens. Just talk; it sends when you stop (press ⌥Space again to send right away). Prefer typing or Wispr Flow? Turn off 🦉 → Voice → *Listen when I press ⌥Space*.
- **🦉 → Voice** picks Hoot's voice (female voices; *Get nicer voices…* downloads Premium ones like Ava, Zoe or Isha).
- **🔊 button** in the chat: Kiri reads replies and test results out loud (click to mute).
- **Click the owl** to chat, **drag** it anywhere, **right-click** for more.
- **📸** = ask about your screen (needs Screen Recording permission once). **👀** = re-run tests on every save.
- **🦉 menu → Set Up Terminal Watching…** adds a one-line hook to `~/.zshrc` (only when you click Add).
- **Focus on/off** uses two Shortcuts you create once: “Kiri Focus On” / “Kiri Focus Off” (Set Focus → Do Not Disturb).
- **Organize folder** only moves files into type folders (never deletes), asks first, and logs moves to `~/Library/Logs/Kiri-moves.log`.
- **Choose project** → the folder Kiri works in. **▶ Run tests** detects npm, swift, cargo, go, pytest/unittest and make.
- Tests fail → the owl gets sad and offers **Fix it**. Turn on **Can edit files** so it can change code.
- **🦉 menu bar → Display:** Auto / Notch (simulate on any Mac) / Desktop pet.

## Try the demo
```bash
open ../kiri-demo            # a tiny Python project with a deliberate bug
../kiri-demo/reset-demo.sh   # put the bug back after a demo
```
See **[DEMO.md](DEMO.md)** for a shot-by-shot 30-second demo video script.

## Build from source
```bash
./make-app.sh          # universal Kiri.app (Apple Silicon + Intel)
./make-app.sh --fast   # quicker, this Mac only
./make-app.sh --install  # build and move into /Applications (do this for Screen Recording)
./make-dmg.sh          # dist/Kiri-1.6.dmg installer
```
Needs Xcode command line tools (Swift 5.9+).

### Project layout
| File | What it is |
|---|---|
| `Sources/Kiri/OwlCharacter.swift` | Hoot: poses, fur eyelids, mood effects |
| `Sources/Kiri/Notch.swift` | Notch island mode and notch detection |
| `Sources/Kiri/PetState.swift` | Moods, speech bubbles, chat and test flow |
| `Sources/Kiri/ClaudeRunner.swift` | Runs `claude -p` headlessly and streams progress |
| `Sources/Kiri/TestRunner.swift` | Detects and runs project tests |
| `Sources/Kiri/HotKeyVoice.swift` | ⌥Space global hotkey and spoken replies |
| `Sources/Kiri/ScreenHelp.swift` | Screenshots for “what's on my screen?” and the Allow dialog |
| `Sources/Kiri/MacActions.swift` | Open apps/links, reminders, focus, organize folders |
| `Sources/Kiri/Watchers.swift` | Test-on-save file watcher and terminal-error hook |
| `Sources/Kiri/Battery.swift` | Low-battery detection |
| `Sources/Kiri/Views.swift` | Chat panel and speech bubble |
| `Sources/Kiri/App.swift` | Windows, menu bar, display mode |
| `characters/` | Character art (drop your own PNGs into `~/Library/Application Support/Kiri/characters/`) |

Other looks (Orbi, Wisp, Termi, Iris, Nimbus, Bubbles, Prism, Sprout) are under right-click → **Character**.

## Troubleshooting
- **Owl thinks forever / "can't reach Claude":** sign in with `claude --setting-sources project,local` → `/login`. Kiri skips a `~/.claude/settings.json` redirect to a local server that isn't running.
- **Log:** `~/Library/Logs/Kiri.log` records what Kiri did (clicks, test runs, errors), readable only by you and capped at 1 MB. It never stores what you say or type, Claude's replies or your terminal commands, only their length. To debug with full text, run `/Applications/Kiri.app/Contents/MacOS/Kiri --verbose-log` (API keys and passwords are still masked).
- **Screen help:** Kiri must be in **/Applications** — macOS won't add an app to Screen Recording from Downloads. Then add it with **+** in *Screen & System Audio Recording* and reopen Kiri.
- **Screen help still says it needs permission:** in *Screen & System Audio Recording*, remove every Kiri entry with **–**, add `/Applications/Kiri.app` with **+**, and reopen Kiri.
- **Permissions survive rebuilds:** `make-app.sh` signs Kiri with a requirement that names only its app ID (`app.kiri.owl`), so macOS keeps Screen Recording, Downloads and Reminders access after updates.

---
MIT licensed, see [LICENSE](../LICENSE). Made with SwiftUI and Claude Code.
