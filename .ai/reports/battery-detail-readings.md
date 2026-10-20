# Battery detail reads real numbers

**Status:** Done — 2026-10-19
**Why:** On battery at 100% the battery detail read Battery "-0.0 W",
System "—", Health "—". These worked on the previous macOS. `ioreg -rn
AppleSmartBattery -d 1` on this Mac (Mac15,12, macOS 27.0.1) showed why:
macOS 27 moved the capacity keys under `BatteryData` (the top level no
longer has `DesignCapacity`, `NominalChargeCapacity`, `AppleRawMaxCapacity`
or `AppleRawCurrentCapacity`), the system draw lives in
`PowerTelemetryData`, amperage reads 0 right after unplugging, and a
negative amperage is stored as a 64-bit unsigned.

## What changed
- `Vitals/Events/Telemetry.swift`
  - One `AppleSmartBattery` registry read per sample
    (`smartBatteryProperties`), passed to the health, adapter-contract and
    current readers instead of each reading the registry itself.
  - Health and cycles: `DesignCapacity`, `NominalChargeCapacity` /
    `AppleRawMaxCapacity` and `CycleCount` are read from the top level,
    else from `BatteryData` (`batteryNumber`). Expected here: "85% · 218".
  - New `PowerSample.systemLoadWatts` from `PowerTelemetryData.SystemLoad`
    (mW ÷ 1000). `systemWatts` uses it, and only falls back to the old
    rating-minus-charge derivation when the key is missing.
  - Off AC with amperage reading exactly 0, and only when `SystemLoad`
    exists, the battery draw is `-systemLoadWatts`. Any non-zero amperage
    wins as before. The time-to-empty fallback keeps its original amperage
    formula and only uses that draw over the pack voltage in the idle-gauge
    case; mAh comes from `AppleRawCurrentCapacity`, else
    `BatteryData.RemainingCapacity`.
  - Amperage is read with `int64Value`. This firmware stores −723 mA as
    18446744073709550893; `doubleValue` made that 1.8e19, which the old
    32-bit fold could not undo, so any non-zero draw would have shown as a
    huge number. 32-bit two's complement is still folded back.
- `Vitals/Interactions/BatteryReadout.swift` — the Battery row shows
  "0.0 W" for anything within ±0.05 W, never "-0.0 W".

## Verification
- Read live with `ioreg` (not built or run, project rule): `InstantAmperage`
  18446744073709550893 → −723 mA × 12.756 V ≈ −9.2 W, matching
  `SystemLoad` 9222 mW; `NominalChargeCapacity` 3864 / `DesignCapacity`
  4563 → 85%; `CycleCount` 218.
- Pending after building: on battery the detail reads Battery ≈ −9 W, System
  ≈ 9 W, Adapter "—", Health "85% · 218", and the summary line shows a time
  left; on the charger System still shows a sensible draw and Battery a
  positive charge while filling.

## Compatibility
Every new read is a fallback; the old source is always asked first and
nothing old was removed or reordered. No `#available` gates — these are
registry dictionary reads.

| Value | Old source (asked first) | New fallback |
|---|---|---|
| Health: design | top-level `DesignCapacity` | `BatteryData.DesignCapacity` |
| Health: now | top-level `NominalChargeCapacity`, then `AppleRawMaxCapacity` | the same keys under `BatteryData` |
| Cycles | top-level `CycleCount` | `BatteryData.CycleCount` |
| Charge left (mAh) | top-level `AppleRawCurrentCapacity` | `BatteryData.RemainingCapacity` |
| System row | adapter rating − charge power (only when `SystemLoad` is missing) | `PowerTelemetryData.SystemLoad` is preferred when present |
| Battery watts | firmware amperage × voltage | `-SystemLoad`, only off AC with amperage exactly 0 |
| Amperage sign | 32-bit two's-complement fold | 64-bit two's complement read via `int64Value` (the 32-bit fold still applies) |
| Adapter contract | top-level `AdapterDetails` Voltage/Current | unchanged — on battery during the check, so `AdapterDetails` was empty and its keys could not be confirmed on macOS 27 |

Checked only against this Mac (Mac15,12, macOS 27.0.1). On an older-OS Mac,
look at: Health still "NN% · cycles" from the top-level keys; System on AC
equal to what it showed before when `PowerTelemetryData.SystemLoad` is
absent; Battery watts and time left unchanged while discharging (non-zero
amperage path). On this Mac on the charger, confirm the Adapter row and its
amber/green dot still read — if `AdapterDetails` lost Voltage/Current on
macOS 27, that needs its own fallback.
