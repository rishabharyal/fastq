# Launcher Keyboard Accessibility & Industry UX Design

**Date:** 2026-07-15  
**Scope:** Fastq launcher panel only (not Fastq Terminal chrome, not VoiceOver deep pass)

## Problem

The launcher is close to Raycast/Alfred keyboard UX but incomplete:

1. Footer hints (`⌫` Quit, `⌘,` Settings) are not wired in the key monitor.
2. Active Windows selection via ↑↓ works, but opening a listed window is easy to miss (double-click / empty-prompt ↩ only).
3. Spacing, row heights, and panel metrics are inconsistent with industry launcher norms.

## Goals

1. **100% keyboard for core launcher flows** — summon, type, navigate chips, navigate Active Windows, open/quit selected window, settings, terminal, dismiss — without a mouse.
2. **Industry-standard panel metrics** — dimensions and spacing aligned with Raycast-class launchers and macOS HIG hit targets.
3. **Footer truth** — every footer keycap must match a real binding.

## Non-goals (this pass)

- Full VoiceOver / rotor / AX protocol overhaul (labels on session rows are in-scope as light polish).
- Redesigning settings or onboarding windows.
- General macOS window switcher (Active Windows remains Fastq agent sessions).

## Industry keyboard model (target)

| Key | Action |
| --- | --- |
| Global hotkey | Toggle launcher |
| Type | Always lands in prompt (type-anywhere) |
| Tab / ⇧Tab | Cycle header chips ↔ prompt |
| ↑ / ↓ | Prompt history ↔ Active Windows selection |
| ↩ | Submit prompt; if navigating sessions (or empty prompt + selection), open selected window |
| ⌫ / Delete | Quit selected Active Window (when a session is selected) |
| ⌘, | Open Settings |
| ⌘T | Open Terminal (existing) |
| ⌘B | Board placeholder (existing) |
| ⌘1 / ⌘2 | Chat / Agent (existing) |
| ⌘P | Project picker (existing) |
| Esc | Peel layers: chip focus → mention → picker → hide |

## Industry UI metrics (target)

Centralize in `LauncherMetrics` and use everywhere in the launcher:

| Token | Value | Rationale |
| --- | --- | --- |
| `panelWidth` | 750 | Raycast-class width |
| `panelExpandedHeight` | 480 | Keep current expanded height |
| `cornerRadius` | 12 | Contemporary floating panel |
| `headerPaddingH` | 16 | Align content columns |
| `headerPaddingTop` | 14 | Compact header |
| `headerPaddingBottom` | 10 | Breathing room above divider |
| `promptMinHeight` | 24 | Single-line |
| `promptMaxHeight` | 72 | ~3 lines |
| `iconButton` | 28×28 | Mic / Go |
| `chipFont` | 12 medium | Readable chip labels |
| `chipPaddingV` | 5 | ~24–26pt chip height |
| `rowMinHeight` | 44 | HIG-friendly list row |
| `rowIcon` | 32×32 | Consistent with row height |
| `rowCornerRadius` | 8 | Selected-row chrome |
| `rowPaddingH` | 12 | |
| `rowPaddingV` | 8 | |
| `listSectionTitle` | 11 semibold caps | |
| `footerPaddingH` | 16 | |
| `footerPaddingV` | 8 | ~36pt footer band |
| `footerFont` | 12 medium | |
| `keyCapFont` | 11 semibold rounded | |

## Architecture

Keep AppKit `NSEvent` local monitors (existing pattern). Extend `installKeyMonitors` + panel Esc/⌘T monitor for missing shortcuts. Extract visual constants to `LauncherMetrics`. Improve session-row interaction: single click selects; ↩ / footer Open activates; double-click still opens.

## Success criteria

- [ ] No footer keycap without a handler.
- [ ] From empty prompt: ↓ selects a session; ↩ opens it and dismisses launcher.
- [ ] ⌫ quits selected session when list has a selection.
- [ ] ⌘, opens settings and hides launcher.
- [ ] Panel width/corners/row heights match `LauncherMetrics`.
- [ ] README documents launcher shortcuts (not only Terminal).
