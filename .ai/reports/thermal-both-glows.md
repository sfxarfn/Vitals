# Both edge glows follow temperature

**Status:** Done — 2026-10-19
**Why:** The right edge glowed for sustained CPU load and the left for heat,
and they almost always lit together — on a fanless chip sustained load is
the heat. Two edges were saying one thing.

## What changed
- `Vitals/Notch/NotchView.swift` — `cpuGlow` input removed. Both glow bars
  draw `thermalGlow`, same tint, and fade in and out together (0.5s).
- `Vitals/Notch/NotchController.swift` — `cpuGlow` property, its publishing
  in `evaluate()`, the `cpuSustainedSeconds` reading field and the
  `NotchRoot` argument removed.
- `Vitals/Events/EventEngine.swift` — `Signal.cpuSustained` removed with
  its loudness, thresholds, value, symbol, title, tint and side, plus
  `Reading.cpuSustainedSeconds` and `EventEngine.cpuGlow`. It was glow-only
  and nothing else read it. The DEBUG hysteresis check now runs on
  `.charged` (holds between 98% and 99.5%) instead.
- `Vitals/Events/Telemetry.swift` — sustained-load tracking
  (`cpuSustainedSeconds`, `sustainedCPUThreshold`, `lastCPUSampleAt`)
  removed. Live CPU % sampling stays — the panel's CPU flank reads it.
- Comments updated in `ThermalReadout.swift`, `EventEngine.swift`,
  `Telemetry.swift`, and the `EventEngine` row of `.ai/README.md`.

## Verification
- Not built or run here (project rule). Pending: the DEBUG self-check
  passes at launch; under fair thermal pressure both edges glow orange and
  fade together, and both go dark at nominal; a long build that pegs the
  CPU without heat no longer lights the right edge; the panel's CPU flank
  still shows a live percentage.

## Notes
- `steering/product.md` still lists a CPU Event; not updated, matching the
  user's instruction to set the steering docs aside.
- `Telemetry.cpuHistory` is still filled but read by nothing; left as-is.
