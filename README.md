# Fastq

Two apps, one workflow:

1. **Fastq** — Raycast-style launcher (customizable hotkey, default ⌘↩)  
2. **Fastq Terminal** — tabbed agent terminal, rendered by **Ghostty** (GPU/Metal, like cmux)  

You only interact with the **launcher**. When you start Claude / Codex / Cursor Agent / Grok / OpenCode, Fastq **starts Fastq Terminal by itself** and opens a new tab there.

Fastq Terminal is also a full manual terminal: **⌘T** (or the **+** button) opens an interactive login shell in the selected project.

### Terminal shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | new / close terminal tab |
| ⌘1…9, ⌃Tab, ⌘⇧[ ] | switch tabs |
| ⌘K | clear screen |
| ⌘C / ⌘V / ⌘A | copy / paste / select all |
| ⌘+ / ⌘− / ⌘0 | font size |
| ⌥←/→, ⌘←/→, ⌘⌫ | word / line editing |
| ⌘↑ / ⌘↓ | jump between prompts (shell integration) |
| ⇧PgUp / ⇧PgDn, ⌘Home / ⌘End | scrollback |

### Launcher shortcuts

| Shortcut | Action |
| --- | --- |
| Global hotkey (default ⌘↩) | Toggle launcher |
| Tab / ⇧Tab | Cycle project → agent → model → attach → prompt |
| ↑ / ↓ | Prompt history (↑) · Active Windows list (↓, works with text in prompt) |
| ↩ | Launch agent / send chat / open selected window |
| ⌫ | Quit selected Active Window (empty prompt or list focus) |
| Esc | Close layer (chip / mention / picker / panel) |
| ⌘1 / ⌘2 | Chat / Agent mode |
| ⌘P | Project picker |
| ⌘V | Attach files/images from clipboard |
| ⌘, | Settings |
| ⌘T | Show Fastq Terminal |
| ⌘B | Board (coming soon) |
| @ | File mention popup |

## Daily use

```bash
chmod +x scripts/run-dev.sh
./scripts/run-dev.sh
open build/DevProducts/Fastq.app
```

Or in Xcode (`open Fastq.xcworkspace`):

1. Build **FastqTerminal** once (⌘B on that scheme) so the `.app` exists  
2. Run **Fastq**  
3. Hotkey (default ⌘↩) → launch an agent → Terminal opens automatically  

You should **not** need to open Fastq Terminal manually.

## Architecture

```
Fastq (launcher)  --auto-launches-->  Fastq Terminal
                 --unix socket----->  create tab / focus / quit / sendText
```

## Terminal engine

Fastq Terminal embeds **libghostty** via the prebuilt
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) Swift package
(`GhosttyTerminal` product) — no Zig toolchain needed. The session model owns
the PTY (`PTYProcess`); Ghostty surfaces attach through the package's
in-memory backend, so IPC (`create tab / focus / quit / sendText`) is
unchanged. `./scripts/setup-ghostty.sh` (build from source, cmux-style) is
kept only as a fallback and is not part of the normal build.

## Layout

```
Fastq/              Launcher
FastqTerminal/      Tabbed terminal (auto-started by launcher)
Shared/             IPC protocol
scripts/run-dev.sh  Build both apps for local use
```
