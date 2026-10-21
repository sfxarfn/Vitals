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
- Nothing was built or run (project rule: the user builds in Xcode). Compile errors are possible, particularly in the CoreAudio calls.
- Still to check on a real call: Meet staying live while muted, the Slack browser Huddle URL (`slack.com/huddle`), Slack/FaceTime/Discord window-title matches, Arc tab lookup across Spaces, Safari Automation prompt.

## Notes
- Meeting was first built as an Extension, then moved to an Activity once it needed two flanks.
- No mic state is shown: mute cannot be read, since these apps hold the microphone open while muted.
- Unverified guesses are marked `ponytail:` in `MeetingWatcher.swift`.
