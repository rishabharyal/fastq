# Fastq

Two apps, one workflow:

1. **Fastq** — Raycast-style launcher (customizable hotkey, default ⌘⌥K)  
2. **Fastq Terminal** — tabbed agent terminal  

You only interact with the **launcher**. When you start Claude / Codex / Cursor Agent / Grok / OpenCode, Fastq **starts Fastq Terminal by itself** and opens a new tab there.

## Daily use

```bash
chmod +x scripts/run-dev.sh
./scripts/run-dev.sh
open build/DevProducts/Fastq.app
```

Or in Xcode (`open Fastq.xcworkspace`):

1. Build **FastqTerminal** once (⌘B on that scheme) so the `.app` exists  
2. Run **Fastq**  
3. Hotkey (default ⌘⌥K) → launch an agent → Terminal opens automatically  

You should **not** need to open Fastq Terminal manually.

## Architecture

```
Fastq (launcher)  --auto-launches-->  Fastq Terminal
                 --unix socket----->  create tab / focus / quit / sendText
```

## Ghostty later (optional, developers only)

You do **not** need this to use Fastq today. v1 already works with a built-in PTY.

`./scripts/setup-ghostty.sh` is only for a future upgrade: swap the simple text view for Ghostty’s GPU renderer (like cmux). End users never run it.

## Layout

```
Fastq/              Launcher
FastqTerminal/      Tabbed terminal (auto-started by launcher)
Shared/             IPC protocol
scripts/run-dev.sh  Build both apps for local use
```
