# Pill refinements

**Status:** Reverted — 2026-10-19. The pills are back to their original look; see `pill-revert.md`.
text pills became icon-only Events and fixed-width Activities). The
failure persistence, colour rule, verdict mapping and `startedAt` plumbing
below still stand.
**Why:** The user approved the before/after mockup for every Event and
Activity pill except the Claude Extension, which is left for now. They also
asked for the song title in the track-change pill to be capped.

## What changed
### One grammar
- `EventPills.swift` — `pillLine(text, tint) { glyph }` puts a glyph and a 12pt
  semibold rounded value with monospaced digits in one flank. It replaces the
  stacked glyph-over-8pt-caption flanks in the verdict, command event, build
  and command activity pills. `flankSlot` is still the only layout.
- `NotchState.swift` (`NotchMetrics`) — new named widths, each with a comment
  naming the string that sets it:
  - `lineFlanks` (72, 72): "12m 34s" beside a 15pt glyph, opposite "Archive"
    beside the 16pt Xcode icon.
  - `chargeFlanks` (52, 52): the bolt plus "100%".
  - `accessoryFlanks` (52, 52): a 14pt ring plus "100%".
  - `trackFlanks` (106, 80): set by the 9-character caps, from a capitalised
    9-character string at 12pt (~76pt) beside the 20pt cover; all-capitals
    names scale to 80%.

  The old stacked widths `verdictFlanks` and `statFlanks` are removed. A build
  pill now has one width with or without a counter. `windowSize` now covers
  the widest pill (track change) with both Extension slots.

### Per pill
- **Build verdict** (`VerdictPill.swift`): Xcode icon + job, then ✓ green +
  "1m 12s" (or "Done"), or ✗ red + "N errors" (or "Failed").
  - Real builds end with Xcode's `xcode-build-succeeded/failed` Behavior
    events. `NotchController.xcodeVerdict` now turns those into `.verdict`.
    Before, they drew as a generic command Event, and `.verdict` only ever
    appeared in previews.
  - The duration is timed from the `xcode-build` lifecycle when it stops
    (`lastXcodeRun`, trusted for 30s).
  - No channel reports an error count, so `errorCount` stays nil and the pill
    says "Failed".
- **vitals-notify event**: subject symbol + subject, then the outcome symbol
  in its tint + the outcome word. The protocol carries no duration.
- **Build with counter**: Xcode icon + job, then a 16pt blue ring + "25%".
- **Build without counter**: Xcode icon + job, then `ElapsedSpinner`: a
  spinner + "0:42", ticking once a second. `XcodeBuildActivity.startedAt`
  comes from the open `xcode-build` lifecycle; with none, it shows the spinner
  alone.
- **vitals-notify activity**: symbol + title, then a spinner + the elapsed time
  from `ExternalActivity.startedAt` ("Running" is gone).
- **Charging started**: ⚡ orange + "64%" on the left, the adapter's "35W" at
  white 0.55 on the right. With no adapter wattage it keeps the old layout.
- **Accessory**: device glyph, then a 14pt ring + "70%". With no level it keeps
  the Bluetooth mark, now white.
- **Track change**: a 20pt cover + the title, then the artist at white 0.55
  (both capped at 9 characters).
  The equaliser is gone from this pill.
  - `TrackChange.titleLimit` and `artistLimit` are both 9, ellipsis included
    (first 8 characters + "…", a plain cut). The first version used 18 and 14
    with a word-boundary cut; the user found that too much.
  - An empty title still means no pill.

### Failures persist
- A failed verdict, and a command event whose outcome is a failure
  (`NotchState.isPersistentFailure`), does not time out. It becomes
  `unseenFailure`: the resting state when no Activity is running, with a 2pt
  red line along the pill's bottom edge (`failureLine`).
- Other Events still queue and show over it (`atRest` counts it), and it
  comes back after them.
- When the pointer reaches the notch, even briefly, `acknowledgeFailure`
  starts the normal 2.6s clock. Opening the panel clears it at once.
- A newer failure replaces an older unseen one. Successes keep the normal
  clock.

### Colours
Green means done or safe, orange attention, red failed or critical, and blue
only for in-progress spinners and rings. Three pills were changed to fit:
- The accessory's 11–20% battery band: yellow → orange.
- The audio-lost headphones: red → orange.
- The Bluetooth mark: blue → white.

### Time formats
- `NotchView.span` for finished runs: "45s", "1m 12s", "1h 4m".
- `NotchView.clock` for elapsed time: "0:42", "1:02:33".

## Verification
- Not built or run here (project rule). After building, check with the debug
  previews (Settings → previews) and real use:
  - Every pill is one line with readable 12pt words, and nothing clips at the
    notch's curved bottom corners.
  - A build that starts from an Xcode Behavior shows a ticking time; with the
    Accessibility grant it shows a ring and the percent.
  - A successful build ends with ✓ and its duration; a failed one with ✗
    "Failed" and a red line that stays until you move the pointer to the
    notch, then leaves about 2.6s later. Hovering until the panel opens
    clears it.
  - While a failure waits, a charging or accessory pill still shows and the
    failure returns after it.
  - A long song title is cut at a word with "…", and the pill stays the same
    width.
  - Plugging in a charger shows ⚡ "NN%" with the watts on the right.
  - A Bluetooth device with a battery shows a ring and the percent.

## Notes
- The Claude Extension pill is untouched, as asked.
- The error count needs a source that does not exist yet, for example a
  Behavior script reading the build log.
