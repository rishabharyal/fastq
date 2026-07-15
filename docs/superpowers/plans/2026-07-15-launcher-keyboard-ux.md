# Launcher Keyboard Accessibility & Industry UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Fastq launcher fully keyboard-operable for core flows and align panel/component dimensions with Raycast-class industry standards.

**Architecture:** Keep the existing AppKit `NSEvent` key-routing model (`LauncherView.installKeyMonitors` + `LauncherPanelController` Esc/⌘T monitor). Wire missing footer shortcuts, tighten Active Windows open/quit keyboard paths, extract `LauncherMetrics` for shared dimensions, and document launcher shortcuts in the README.

**Tech Stack:** SwiftUI, AppKit (`NSEvent`, `NSPanel`), existing `LauncherKeyRouter` bridge.

**Spec:** `docs/superpowers/specs/2026-07-15-launcher-keyboard-ux-design.md`

## Global Constraints

- Scope: Fastq launcher panel only (`Fastq/Views/LauncherView.swift`, related helpers, README).
- Do not change Fastq Terminal keyboard chrome in this plan.
- Do not introduce SwiftUI `.onKeyPress` as a full replacement for `NSEvent` monitors — extend the current monitors.
- Footer keycaps must always match real bindings.
- Prefer small, focused edits; no unrelated refactors.
- Do not commit unless the user explicitly asks.

## File map

| File | Responsibility |
| --- | --- |
| `Fastq/Views/LauncherMetrics.swift` | **Create** — shared dimension/spacing/font tokens |
| `Fastq/Views/LauncherView.swift` | Apply metrics; wire ⌫ / improved ↩ open; session row a11y; chip/footer sizing |
| `Fastq/Controllers/LauncherPanelController.swift` | Wire ⌘, Settings beside existing ⌘T; use metrics for initial panel size |
| `README.md` | Add launcher shortcut table |

---

### Task 1: Add `LauncherMetrics` tokens

**Files:**
- Create: `Fastq/Views/LauncherMetrics.swift`
- Modify: `Fastq.xcodeproj/project.pbxproj` (ensure new Swift file is in the Fastq target — Xcode folder sync may auto-include; verify)

**Interfaces:**
- Produces: `enum LauncherMetrics` with static `CGFloat` / sizing constants listed in the spec

- [ ] **Step 1: Create metrics file**

```swift
import CoreGraphics

/// Industry-standard launcher panel metrics (Raycast-class + macOS HIG hit targets).
enum LauncherMetrics {
    static let panelWidth: CGFloat = 750
    static let panelExpandedHeight: CGFloat = 480
    static let cornerRadius: CGFloat = 12

    static let headerPaddingH: CGFloat = 16
    static let headerPaddingTop: CGFloat = 14
    static let headerPaddingBottom: CGFloat = 10

    static let promptMinHeight: CGFloat = 24
    static let promptMaxHeight: CGFloat = 72
    static let iconButtonSize: CGFloat = 28

    static let chipFontSize: CGFloat = 12
    static let chipIconSize: CGFloat = 10
    static let chipPaddingH: CGFloat = 8
    static let chipPaddingV: CGFloat = 5
    static let chipSpacing: CGFloat = 6

    static let rowMinHeight: CGFloat = 44
    static let rowIconSize: CGFloat = 32
    static let rowIconCornerRadius: CGFloat = 8
    static let rowCornerRadius: CGFloat = 8
    static let rowPaddingH: CGFloat = 12
    static let rowPaddingV: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let listHorizontalInset: CGFloat = 10
    static let listSectionTitleSize: CGFloat = 11

    static let footerPaddingH: CGFloat = 16
    static let footerPaddingV: CGFloat = 8
    static let footerFontSize: CGFloat = 12
    static let keyCapFontSize: CGFloat = 11
    static let keyCapPaddingH: CGFloat = 5
    static let keyCapPaddingV: CGFloat = 2
    static let keyCapCornerRadius: CGFloat = 4
}
```

- [ ] **Step 2: Verify the file is part of the Fastq target**

If the project uses folder references / synchronized groups, it may auto-pick up. If not, add `LauncherMetrics.swift` to the Fastq target in `project.pbxproj`.

- [ ] **Step 3: Build check**

Run: `xcodebuild -scheme Fastq -configuration Debug build 2>&1 | tail -30`  
(or `./scripts/run-dev.sh` if that is the project’s preferred path)  
Expected: build succeeds (or at least compiles the new file with no errors).

---

### Task 2: Apply metrics to launcher chrome (panel, header, chips, rows, footer)

**Files:**
- Modify: `Fastq/Views/LauncherView.swift`
- Modify: `Fastq/Controllers/LauncherPanelController.swift`

**Interfaces:**
- Consumes: `LauncherMetrics.*`
- Produces: visually updated launcher matching spec tokens

- [ ] **Step 1: Replace hard-coded panel size in `LauncherView.body`**

Change:

```swift
.frame(width: 720)
.frame(height: showsContentArea ? 480 : nil)
```

To:

```swift
.frame(width: LauncherMetrics.panelWidth)
.frame(height: showsContentArea ? LauncherMetrics.panelExpandedHeight : nil)
```

Also update corner radius on clip/overlay/background from `16` → `LauncherMetrics.cornerRadius`.

- [ ] **Step 2: Header / prompt / icon buttons**

- Header padding → `headerPaddingH/Top/Bottom`
- Prompt clamp → `promptMinHeight` / `promptMaxHeight`
- Mic + Go frames → `iconButtonSize`
- Chip row spacing → `chipSpacing`
- `ChipLabel` fonts/paddings → chip tokens

- [ ] **Step 3: Session list + `SessionRow`**

- Section title size → `listSectionTitleSize`
- Row icon 32×32, corner 8, min height 44 via padding + frame
- Row selection corner → `rowCornerRadius`
- Horizontal list inset → `listHorizontalInset`

- [ ] **Step 4: Footer + keycaps**

- Footer padding → `footerPaddingH/V`
- `FooterAction` / `KeyCap` fonts and keycap chrome → footer/keyCap tokens

- [ ] **Step 5: Panel controller initial size**

In `ensurePanel()`, use:

```swift
contentRect: NSRect(
    x: 0, y: 0,
    width: LauncherMetrics.panelWidth,
    height: LauncherMetrics.panelExpandedHeight
)
```

- [ ] **Step 6: Manual visual check**

Build and open launcher (empty + with sessions). Confirm width ~750, tighter footer, 44pt-ish rows, 12pt corners.

---

### Task 3: Wire footer keyboard shortcuts (⌫ Quit, ⌘, Settings)

**Files:**
- Modify: `Fastq/Views/LauncherView.swift` (`installKeyMonitors`)
- Modify: `Fastq/Controllers/LauncherPanelController.swift` (`installEscapeMonitor`)

**Interfaces:**
- Consumes: `selectedSessionID`, `sessions`, `launcher.quit`, `onOpenSettings` / `openSettings`
- Produces: real handlers for footer keycaps

- [ ] **Step 1: Add ⌘, in panel controller next to ⌘T**

In `installEscapeMonitor`, after the ⌘T branch:

```swift
if mods == .command, event.charactersIgnoringModifiers == "," {
    DispatchQueue.main.async {
        self?.openSettings()
    }
    return nil
}
```

- [ ] **Step 2: Add Delete/Backspace quit in `LauncherView.installKeyMonitors`**

Inside the keyDown monitor, after command-shortcut handling and before Tab handling (and only when project picker / mention popup are closed):

```swift
// ⌫ / Forward Delete — quit selected Active Window (footer "Quit").
if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
    if LauncherKeyRouter.shared.isMentionPopupOpen { return event }
    if let id = selectedSessionID,
       let session = sessions.sessions.first(where: { $0.id == id }) {
        DispatchQueue.main.async {
            launcher.quit(session)
        }
        return nil
    }
}
```

Key codes: `51` = Delete/Backspace, `117` = Forward Delete.

- [ ] **Step 3: Guard against deleting while typing**

Only consume ⌫ when the prompt is empty **or** `isNavigatingTabs` is true — otherwise let the text view delete characters:

```swift
if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
    if LauncherKeyRouter.shared.isMentionPopupOpen { return event }
    let promptEmpty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard promptEmpty || isNavigatingTabs else { return event }
    guard let id = selectedSessionID,
          let session = sessions.sessions.first(where: { $0.id == id }) else {
        return event
    }
    DispatchQueue.main.async { launcher.quit(session) }
    return nil
}
```

- [ ] **Step 4: Manual keyboard test**

1. Open launcher with ≥1 session. Empty prompt → ↓ select → ⌫ quits.  
2. Type text → ⌫ deletes characters (does not quit).  
3. ⌘, opens Settings and hides launcher.

---

### Task 4: Reliable Active Windows open via keyboard

**Files:**
- Modify: `Fastq/Views/LauncherView.swift` (`submitPrimary`, `handleArrowKey`, `SessionRow`)

**Interfaces:**
- Consumes: `isNavigatingTabs`, `selectedSessionID`, `launcher.focus`
- Produces: ↩ opens selected window whenever list navigation is active

- [ ] **Step 1: Prefer session open when navigating tabs**

Update `submitPrimary()`:

```swift
private func submitPrimary() {
    if showProjectPicker { return }
    if mode == .chat {
        sendChatMessage()
        return
    }
    // While arrow-navigating Active Windows, ↩ always opens the selection
    // (Raycast/Alfred result-activation model).
    if isNavigatingTabs,
       let session = sessions.sessions.first(where: { $0.id == selectedSessionID }) {
        launcher.focus(session)
        onDismiss()
        return
    }
    if let session = sessions.sessions.first(where: { $0.id == selectedSessionID }),
       prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        launcher.focus(session)
        onDismiss()
        return
    }
    settings.recordPrompt(prompt)
    historyIndex = nil
    Task { await launchAgent() }
}
```

- [ ] **Step 2: Enter list-nav mode immediately when selecting via click**

In `SessionRow` / list `onSelect`, also set `isNavigatingTabs = true` so a click-selected row opens with ↩ without requiring an arrow first. Pass a binding or callback from `sessionList`:

```swift
onSelect: {
    selectedSessionID = session.id
    isNavigatingTabs = true
}
```

- [ ] **Step 3: Accessibility labels on rows**

On `SessionRow` root:

```swift
.accessibilityElement(children: .combine)
.accessibilityAddTraits(isSelected ? .isSelected : [])
.accessibilityLabel("\(session.title), \(session.subtitle), \(session.status == .launching ? "Launching" : "Running")")
.accessibilityHint("Return to open, Delete to quit")
```

Ensure quit button keeps its own label: `.accessibilityLabel("Quit \(session.title)")`.

- [ ] **Step 4: Manual test**

1. Empty prompt → ↓ → ↩ opens Terminal tab and hides launcher.  
2. Click a row → ↩ opens it.  
3. Double-click still opens.  
4. Non-empty prompt + ↩ still launches agent (unless `isNavigatingTabs`).

---

### Task 5: Document launcher shortcuts in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add launcher shortcut table after the Terminal table**

```markdown
### Launcher shortcuts

| Shortcut | Action |
| --- | --- |
| Global hotkey (default ⌘↩) | Toggle launcher |
| Tab / ⇧Tab | Cycle project → agent → model → attach → prompt |
| ↑ / ↓ | Prompt history ↔ Active Windows |
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
```

- [ ] **Step 2: Sanity-read README** — tables render; no contradictory claims.

---

### Task 6: End-to-end verification

- [ ] **Step 1: Build** Fastq (+ Terminal if needed via `./scripts/run-dev.sh`).
- [ ] **Step 2: Keyboard checklist**

| Flow | Expected |
| --- | --- |
| Hotkey → type → ↩ | Launches agent |
| Empty → ↓ → ↩ | Opens selected Active Window |
| Empty → ↓ → ⌫ | Quits selected session |
| Typing → ⌫ | Deletes text only |
| ⌘, | Settings |
| ⌘T | Terminal |
| Tab through chips → Esc | Returns to prompt |
| Esc Esc | Hides launcher |

- [ ] **Step 3: Visual checklist** — width 750, corner 12, ~44pt rows, footer keycaps match behavior.

---

## Spec coverage

| Spec requirement | Task |
| --- | --- |
| `LauncherMetrics` tokens | Task 1–2 |
| Wire ⌫ Quit | Task 3 |
| Wire ⌘, Settings | Task 3 |
| Reliable ↩ open Active Windows | Task 4 |
| Session row a11y labels | Task 4 |
| README launcher shortcuts | Task 5 |
| Success criteria verification | Task 6 |

## Placeholder / consistency self-review

- No TBD steps.
- Key codes and exact code blocks included.
- `isNavigatingTabs` used consistently for open + quit guards.
- Metrics names match between Task 1 and Task 2.
