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
- **Voice:** press **⌥Space in any app**, talk (works great with Wispr Flow), and Kiri **reads the answer out loud**.
- **Safe by default:** read-only until you flip **Can edit files**, and it can only run your test commands.
- **Light on your Mac:** 8–24 fps, GPU-drawn, and it pauses when hidden.

| Notch mode (MacBook Pro / Air with notch) | Desktop mode (every Mac) |
|---|---|
| <img src="docs/kiri-notch.png" width="420"> | <img src="docs/kiri-owl.png" width="420"> |

## Install
1. Download **`Kiri-1.0.dmg`** from Releases, open it, and drag **Kiri** into **Applications**.
2. First launch: **right-click Kiri → Open → Open** (it isn't notarized yet).
3. One-time Claude setup in Terminal:
   ```bash
   npm install -g @anthropic-ai/claude-code   # if you don't have `claude` yet
   claude --setting-sources project,local       # then type /login and sign in
   ```
4. Click **Allow** when macOS asks whether Kiri can read your project folder.

Requires **macOS 14+**, Apple Silicon or Intel.

## Use it
- **Press ⌥Space in any app** → chat opens with the text box focused. Talk with **Wispr Flow** or type, then press **Enter** to send (Shift+Enter = new line). ⌥Space again closes it.
- **🔊 button** in the chat: Kiri reads replies and test results out loud (click to mute).
- **Click the owl** to chat, **drag** it anywhere, **right-click** for more.
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
./make-dmg.sh          # dist/Kiri-1.0.dmg installer
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
| `Sources/Kiri/Views.swift` | Chat panel and speech bubble |
| `Sources/Kiri/App.swift` | Windows, menu bar, display mode |
| `characters/` | Character art (drop your own PNGs into `~/Library/Application Support/Kiri/characters/`) |

Other looks (Orbi, Wisp, Termi, Iris, Nimbus, Bubbles, Prism, Sprout) are under right-click → **Character**.

## Troubleshooting
- **Owl thinks forever / "can't reach Claude":** sign in with `claude --setting-sources project,local` → `/login`. Kiri skips a `~/.claude/settings.json` redirect to a local server that isn't running.
- **Folder permission prompt keeps returning:** unsigned rebuilds look like a new app to macOS. Click Allow once per build.
- **Log:** `~/Library/Logs/Kiri.log` records clicks, Claude requests and test runs.

---
Made with SwiftUI and Claude Code.
