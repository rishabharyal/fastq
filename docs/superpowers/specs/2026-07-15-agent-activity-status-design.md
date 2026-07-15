# Agent Activity Status — Multi-Tool Architecture

**Date:** 2026-07-15

## Goal

Surface **Working / Needs you / Done** for **any** AI CLI in Fastq Terminal — not Claude-only.

## Layers

```
Shared (FastqIPC)
  AgentActivity + OSC codec (`fastq:<state>`)
  AgentActivityInterpreter  ← titles + PTY heuristics (all tools)

Fastq launch-time
  AgentActivityAdapter (protocol)
  AgentActivityRegistry     ← one adapter per AgentToolKind
  prepareLaunch() → extra CLI args / setup files

Fastq Terminal run-time
  TerminalSession           ← applies interpreter on OSC + PTY + exit
  SessionInfo.activity      ← polled by launcher

Launcher UI
  SessionRow status chrome  ← quiet dot + label (brand coral only for Needs you)
```

## Contract (universal)

Any tool can report status by setting the terminal title to:

- `fastq:working`
- `fastq:waiting`
- `fastq:done`
- `fastq:idle`

Adapters that can install hooks (Claude today) emit that contract via `terminalSequence`.  
Tools without hooks still get:

1. **working** on launch + on PTY output  
2. **waiting** when common permission/prompt phrases appear in output  
3. **done** on process exit  

## Adding a new CLI

1. Add `AgentToolKind` case (existing flow).  
2. Optionally add `SomeToolActivityAdapter` that implements `prepareLaunch()` (hooks/flags).  
3. Register it in `AgentActivityRegistry`.  
4. No Terminal or launcher UI changes required.
