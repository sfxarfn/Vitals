# Build pill appears like every other pill

**Status:** Done — 2026-10-18
**Why:** The in-progress build pill's entrance was erratic: three stacked
tricks (an `OutwardFromNotch` offset, `outward` branch transitions, and a
spinner loop leaking onto position) fought each other.

## What changed
- `Vitals/Activities/BuildPill.swift` — uncommitted tricks reverted to
  `HEAD`; they patched the slide-from-the-right that the content-layer fix
  in `peek-spread-from-centre.md` removed at the root. `XcodeBuildSpinner`'s
  loop is scoped to the rotation with `.animation(_:body:)`.
- `Vitals/Notch/NotchView.swift` — build and external Activity pills fade in
  over 0.2s with no delay, the same as every Event pill.

## Verification
- Not built or run here (project rule). Pending: start a build — the pill
  grows symmetric and its content fades in place, spinner turning on the
  spot; progress arriving cross-fades spinner → counter.

## Notes
- The reverted diff is saved at the session scratchpad as
  `sofyan-buildpill-before-revert.diff` (not in the repo).
