# Vitals — Design

How the notch looks and moves. What it says is [`product.md`](product.md).

## Shape

- One outline in every state: the notch silhouette, flaring outward at the top
  corners so it grows out of the bezel rather than sitting on it.
- Opaque black, always. The panel reads as more bezel, never as a window.
- Idle is flush with the bezel. Anything grown lifts off it and casts a shadow.

## Layout

- **The notch's own width is dead space.** The camera housing sits over it, so
  content lives in the two flanks and the middle stays empty.
- Content hugs the notch. Each flank pins its content to the inner edge, against
  the camera housing, so the two sides read as one tight cluster rather than two
  things pushed apart.

## Width

The notch stays as narrow as its content allows. Width is bought, not chosen: a
state that says less grows less. Every pixel past the bezel is borrowed from the
menu bar, so the question is always *what can come out*, never what can fit.

- Say it in the fewest characters that still carry it. A number beats a word —
  "48°" says more than "Cooled down" and costs half the room. A glyph beats a
  label.
- **Two live sides are equal.** Whichever has more to say sets the width, and the
  other matches it. A shape that leans by a few points reads as a mistake.
- **One live side grows one side.** Nothing to say on the far flank means nothing
  is bought there — the notch leans on purpose, all the way, and the lean is what
  says which subsystem is talking.
- Slack falls outward. Content is already against the housing, so what is left
  over sits between the content and the bezel, where it reads as breathing room.
- The notch's own width is free. Anything that ends up behind the camera housing
  costs nothing, so pulling content inward is always the cheaper direction.
- Widths are shared only where one state can replace another under a resting
  pointer — the shape must not resize under the cursor. That is the single case
  where matching beats shrinking.
- Each family has a ceiling, set by the longest string it can ever draw. Change
  the string and the ceiling moves with it.

## Growth

Height is what separates the categories on sight, so only one of them is allowed
to use it.

- **Events and Activities** — horizontal only. The notch stays one row tall.
- **Peek** — horizontal, and twice the notch's height.
- **Panel** — horizontal, and three times the notch's height.

## Motion

- Grow and shrink. Never cut, never fade one size into another.
- A state's own numbers changing is not a state change, and must not re-run the
  growth.
