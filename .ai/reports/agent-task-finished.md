# agent-task-finished — Claude / Cursor task-finished notice

**Status:** Done — 2026-11-06 (builds; not yet confirmed on screen)
**Why:** Know the moment Claude Code or Cursor finishes a turn without watching its window. The notch shows the agent's mark and a check, and glows in the agent's colour.

## What changed
- `Vitals/Events/AgentFinishedPill.swift` — new. `AgentFinish` (agent, tint, timestamp) and the pill: an agent mark (34pt) in the left flank, a check (31pt) in the right, each in a 34pt slot hugging the housing, and a 12pt caption ("<Agent> task finished", 80% white) centred under the housing. One margin (`agentAir`, ~21pt on a 38pt housing) above, below and outboard of each glyph, and under the caption's baseline.
- `Vitals/Notch/OutlineGlow.swift` — new. `OutlineGlow`: 64 overlapping Core Animation dots with a Gaussian falloff and a sin² swell on the notch's open outline, a faint tint everywhere and a swell travelling top-left → round the bottom → top-right (stagger = travel). Glow only — no border line (removed on request). Reduce Motion holds a static tint.
- `Vitals/Notch/Marks.swift` — `CursorMark`, the cube as an outline.
- `Vitals/Notch/NotchState.swift` — `.agentFinished`, `agentGlyph` 34, `agentHeight` (twice the housing, Peek's), `agentAir` and `agentFlanks` derived from them. An earlier version put a sentence on a row under the housing and was dropped for these two large glyphs.
- `Vitals/Notch/NotchView.swift` — shape key, content route, glow behind the shape.
- `Vitals/Notch/NotchController.swift` — files `claude-finished` / `cursor-finished` Command Events as `.agentFinished` (newest per agent), holds 6s, two previews under "Agents".
- `installation-files/claude-extension.sh` — `finished` mode; new `installation-files/cursor-finished.sh`.
- `README.md`, `.ai/steering/{product,design,lifecycles,structure}.md`, `.ai/README.md` — documented. `design.md` Growth now names this as the one Event allowed to grow (to Peek's height).

## Verification
- `sh -n` on both hook scripts; `plutil` extraction of `status` checked against a sample payload (present → `completed`; absent → falls through and announces).
- Debug `xcodebuild` succeeded and the app launched with `vitals-notify event claude-finished` accepted (run at the user's request). The final mark-and-check layout and the glow were not looked at on screen by me; colours, glow size/strength, glyph sizes and the swell's travel are tuned from the HTML mock, not from the real notch.
- Not verified: that Claude's `Stop` and Cursor's `stop` payload and config shape match what the scripts assume (Cursor's is from secondhand documentation — marked `ponytail:` in the script).

## Notes
- No new protocol verb: the hooks send ordinary events, so `vitals-notify` and `CommandReceiver` are unchanged.
- Not built, as designed: a subtitle (project, duration), a `StopFailure` variant, hover-to-hold.
- `Stop` fires after every turn, so a one-line reply announces too.
