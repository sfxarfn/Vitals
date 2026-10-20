# Track-change pill

**Status:** Done — 2026-10-19
**Why:** The user wanted a pill when the track changes on its own: the album
art on the left and the equaliser on the right. It should never appear for a
skip made from the notch.

## Cost, measured first
A `stream` has to run while the panel is closed, so I measured an idle
adapter process on this Mac (macOS 27.0.1) with `ps`, sampling every 5s:
- `stream --no-artwork --debounce=500`: 0.0% CPU, ~27 MB RSS, 0.02s CPU time
  over 30s.
- `stream --debounce=100` (with artwork): 0.0% CPU, ~33 MB RSS, 0.03s CPU time
  over 20s.

The process is event-driven: it wakes only when the player says something,
and nothing ticks. That cost is acceptable, so there is one always-on stream
with artwork, not two streams or a separate artwork fetch. Opening the panel
no longer spawns perl at all, which also removes the 0.4s start delay from the
lag fix.

## What changed
- `Vitals/Interactions/NowPlaying.swift`
  - The stream starts at launch (after the background unzip) and restarts if
    it dies, whether or not the panel is open. `active` now only suppresses
    the pill and drives the AppleScript fallback's polling.
  - `willTerminateNotification` ends the perl child on quit. A Vitals killed
    outright, for example stopped from Xcode, leaves it until its next write
    fails on the closed pipe.
  - `noticeTrackChange()` fires `onTrackChange(TrackChange)` when the identity
    (title, artist and album) changes and the track is playing. It does not
    fire for:
    - the stream's first line after launch or a restart (`seenFirst`);
    - an empty title or nothing playing;
    - pause or resume, which keep the identity;
    - a change while the panel is open;
    - the first change within 3s of the panel's own previous or next
      (`suppressUntil`, cleared by that change).

    A change whose `playing` arrives in a later line still fires, as long as
    that is within 1s.
  - New `TrackChange` (title, artist, artwork thumbnail, tint, time).
- `Vitals/Notch/NotchState.swift` — `case trackChange(TrackChange)`, a
  whole-notch Event with `glyphFlank` flanks on both sides (a 22pt cover
  against the bars, the same pairing as the accessory pill).
- `Vitals/Notch/NotchController.swift`
  - A track change replaces any change still waiting in the queue.
  - `presentNext` drops one that has waited more than 1s.
  - `presentAlone` holds it for 2s (`duration(of:)`); other Events keep 2.6s.
- `Vitals/Events/EventPills.swift` — `trackChangePill`: a 22pt cover with
  radius 5 (a `music.note` stand-in until the cover lands), hugging the
  housing; on the right, the equaliser in the cover's colour at 1.4× and
  centred. One row, no shadow, like the other Events.
- `Vitals/Notch/NotchView.swift` — shape key and content case.
- `Vitals/Interactions/NowPlayingPage.swift` — `EqualizerBars` is internal so
  the pill can use it. Under Reduce Motion it is still and the pill still shows.

## Verification
- Cost measured as above. App code not built or run here (project rule).
- Pending after building:
  - Let a playlist roll into the next song with the panel closed: the pill
    shows the cover and moving bars for about 2s.
  - Skip with the panel's time buttons: no pill.
  - Skip from the player app or the keyboard: pill.
  - Pause, then resume: no pill.
  - Launching Vitals mid-song: no pill.
  - With the panel open when a song changes: no pill, and none after closing.
  - `ps` on the perl child: 0% CPU while idle, gone after Quit Vitals.

## Notes
- The pill reads the adapter only. Under the AppleScript fallback (polled only
  while the panel is open) there is no pill.
- If the cover arrives in a later line than the title, the pill shows the
  note glyph. It does not swap the cover in mid-pill.
