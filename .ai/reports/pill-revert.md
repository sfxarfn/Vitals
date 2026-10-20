# Pills reverted to the original look

**Status:** Done — 2026-10-19
**Why:** The user asked for every Event and Activity pill to go back to the
original design from before this session. They chose to also revert
failure persistence and the colour changes, and to keep heat as glow only.

## What changed
- `EventPills.swift`, `VerdictPill.swift`, `BuildPill.swift`,
  `ExternalActivityPill.swift` are restored from `HEAD`: the glyph-over-8pt
  caption stacks, the stacked build counter, `compactPill`'s glyph | value,
  and the accessory ring. On top of `HEAD`:
  - `sidedPill` and its flank are removed, because there are no one-sided
    Events left. `compactValue` is power-only.
  - Two pills that did not exist at `HEAD` are drawn in the old style:
    - `trackChangePill`: a 22pt cover | the equaliser.
    - `vpnPill`: an orange lock over "VPN" | a globe over "Connected", or a
      clock over "30m"/"1h"/….
  - The build spinner keeps its scoped rotation (a bug fix, not a look).
- `NotchState.swift`
  - `glyphFlank`, `statFlanks` and `verdictFlanks` restored; `baseFlanks`
    and `windowSize` are back to `HEAD`'s, with `.trackChange` on glyph flanks
    and `.vpn` on verdict flanks.
  - Removed: `activityFlanks`, `vpnReminderFlanks`, `flankSlot(outer:)` and
    `isPersistentFailure`.
- `NotchController.swift` — failure persistence removed (`unseenFailure`,
  `failureDismiss`, `acknowledgeFailure` and their hooks). A failed build or
  command now leaves on the Event clock like any other pill.
- `Accessory.swift` — restored (yellow 11–20%). With the `HEAD` pills, audio
  lost is red again and the Bluetooth mark blue.
- `XcodeBuildActivity.startedAt` and its plumbing removed (only the elapsed
  clock used it).

## Kept from this session
- Heat is glow-only on both edges, with no thermal pills (critical glows red).
- Xcode's `xcode-build-succeeded/failed` events are still drawn as the build
  verdict pill (old style), not as the generic command pill.
- The VPN connect and reminder logic (back-off at 30m, 1h, 2h and 4h) and the
  track-change detection.

## Verification
- Not built or run here (project rule). Pending: open Settings → Preview and
  check every pill against the original look. Check that a failed build
  disappears on its own after about 2.6s, and that the VPN and track-change
  pills draw in the old stacked style.
- The pre-revert pill files are saved in the session scratchpad
  (`pre-revert/`), outside the repo.
