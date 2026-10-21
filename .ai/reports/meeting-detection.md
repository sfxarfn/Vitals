# meeting-detection — Live call detection and return-to-meeting

**Status:** Done — 2026-10-21
**Why:** After screen sharing or multitasking the ongoing call is hard to find again. The notch should show a call is live and bring its window back in one click.

## What changed
- `Vitals/Activities/MeetingWatcher.swift` — new. CoreAudio per-process input listeners (push-only, no timer) identify Google Meet and Slack Huddles in Chrome, Arc and Safari, and the FaceTime, Slack and Discord apps. Browser calls are found by tab URL over `osascript`; native apps by window title over Accessibility. Owns `returnToMeeting()`.
- `Vitals/Activities/MeetingPill.swift` — new. `.meeting` state: video glyph with a green live dot (left, centred), call clock (right).
- `Vitals/Interactions/MeetingPage.swift` — new. Always-present third panel page: "No meeting", or app tile, room and clock. Tile and room are one button that returns to the call; hover underlines the room and slides a return arrow in.
- `Vitals/Interactions/PanelView.swift` — `PanelPage.meeting`; opening order is Shelf (holds something or a file in hand), then Meeting while a call is live, then Now Playing.
- `Vitals/Notch/NotchState.swift`, `NotchView.swift`, `NotchController.swift` — `.meeting` Activity state, `meetingFlanks` (42, 42), watcher wiring and resting-state arbitration (a newer reported Activity wins; a toolbar-counter-only build outranks a call).
- `Vitals.xcodeproj/project.pbxproj` — Apple Events usage text names the browsers.
- `.ai/steering/*`, `.ai/README.md`, `README.md` — Meeting documented as an Activity plus a panel page; permissions and a product-style README front section added.

## Verification
- Run by the user in Xcode, read back from the unified log (subsystem `com.polkka.Vitals`, category `meeting`): a Meet join in Chrome was identified 0.16s after Chrome's microphone opened; a leave cleared the meeting 2.4s after the microphone closed (2s end grace).
- Per-process and input-device listeners were measured missing joins, so a 2-second flag read backs them up (`lifecycles.md`).
- Fixed after first run: the tab-scan AppleScript used `tab` inside `tell Chrome` (the browser's tab class), which made it fail.
- Not verified: Arc, Safari, FaceTime, Discord, Slack Huddle (app and browser), and Meet staying live while muted beyond the one Chrome call.
## Notes
- Meeting was first built as an Extension, then moved to an Activity once it needed two flanks.
- No mic state is shown: mute cannot be read, since these apps hold the microphone open while muted.
- Unverified guesses are marked `ponytail:` in `MeetingWatcher.swift`.
