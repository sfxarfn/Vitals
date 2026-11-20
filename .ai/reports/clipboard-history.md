# clipboard-history — Clipboard page in the panel

**Status:** Done — 2026-11-20
**Why:** A fourth panel page with recent copies, picked from five mockups: the latest copy in a one-third card, the three before it as rows, press to paste.

## What changed
- `Vitals/Interactions/ClipboardHistory.swift` (new) — `ClipboardHistory` and `Clip`: `changeCount` read once a second (0.5s tolerance), 20 copies in memory, concealed/transient/auto-generated copies and anything over 12 MB skipped, put-back that keeps every pasteboard type, and the ⌘V that pastes it.
- `Vitals/Interactions/ClipboardPage.swift` (new) — the page: an exact-third latest card, three rows, an age or a check per clip, an empty state ("Nothing copied"). A press pastes and closes the panel; ⌥ copies only.
- `Vitals/Interactions/PanelView.swift` — `PanelPage.clipboard`, routed in the slot. Not added to `openingPage`.
- `Vitals/Notch/NotchView.swift`, `Vitals/Notch/NotchController.swift` — the controller owns and starts `ClipboardHistory` and hands it to the view.
- `.ai/steering/product.md`, `.ai/steering/lifecycles.md`, `.ai/steering/structure.md`, `.ai/README.md`, `README.md` — the page, its lifecycle, the code map, and the Accessibility grant now also covering paste.

## Verification
- Nothing built or run (project rule). Xcode build and on-device checks are pending.

## Notes
- Paste needs the Accessibility grant; without it, or with secure input on, a press copies only and the panel stays open.
- Reading the pasteboard in the background may trigger macOS's pasteboard privacy prompt on recent releases. Not checked; if it appears, Vitals needs "Allow" under Privacy & Security → Paste from Other Apps.
- The swipe paging branch `claude/sofyan-panel-swipe-00a2cb` also edits `PanelView.swift`; expect a small merge conflict. Its swipe walks `PanelPage.allCases`, so it reaches the new page with no change.
