# Settings window is always obvious

**Status:** Done — 2026-10-19
**Why:** The user often could not tell whether Settings was already open.
Vitals runs with the `.accessory` activation policy, and `SettingsLink`
opened the window without activating the app, so it usually landed behind the
frontmost app. A second click then looked like it did nothing.

## What changed
- `Vitals/VitalsApp.swift`
  - New `SettingsWindow` (`@MainActor` enum) owns the window:
    - `attach(_:)` records the window SwiftUI opened and observes
      `NSWindow.willCloseNotification` on it.
    - `bringForward()` switches the policy to `.regular` (Dock icon and ⌘Tab
      while Settings is open), calls `NSApp.activate()`, and calls
      `makeKeyAndOrderFront` / `orderFrontRegardless`.
    - On close, the policy goes back to `.accessory`, deferred one run-loop
      turn so the close finishes first. macOS then returns focus to the
      previous app, and the nonactivating notch panel is not touched. A
      reopen in that turn cancels the switch.
  - The window is found with `WindowReader`, an `NSViewRepresentable` in
    `SettingsView`'s background. Its `viewDidMoveToWindow` fires on every open,
    first or later, whether or not the window becomes key. That is why it was
    chosen over `didBecomeKey`, which an inactive app's window may never post.
    It hands the window over on the next turn, after SwiftUI has finished
    setting the window up.
- `Vitals/Notch/NotchController.swift` (`NotchRoot`) — the context menu's
  `SettingsLink` is now a Button that calls `@Environment(\.openSettings)` and
  then `SettingsWindow.bringForward()`. `openSettings` reuses an open window,
  so there is never a second one, and the second click now refocuses it.
- `README.md` — the accessory-app note now says Vitals shows in the Dock and
  ⌘Tab while Settings is open.
- No icon change needed: `Assets.xcassets/AppIcon.appiconset` has the full set
  from 16 to 1024, so the Dock icon is not blank.

## Verification
- Not built or run here (project rule). After building:
  - With another app frontmost, right-click the notch → Settings…: the window
    comes to the front, focused.
  - Put another app in front again, then choose Settings… again: the same
    window comes back, with no second window.
  - While Settings is open, Vitals is in the Dock and ⌘Tab. Close it and the
    icon goes, with focus returning to the app you were in.
  - With Settings open, hovering the notch still opens the panel, the shelf
    takes drops, and the panel closes normally.
  - Quit from the Dock icon while Settings is open: Vitals quits cleanly and the
    Now Playing perl process ends (`pgrep -fl mediaremote-adapter` is empty).

## Notes
- While Vitals is a regular app, its standard app menu (with ⌘, for
  Settings) is in the menu bar. That is expected for a focused window.
