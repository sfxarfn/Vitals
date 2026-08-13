# Vitals — Design

How the notch looks and moves. What it says is [`product.md`](product.md).

## Shape

- One outline in every state: the notch silhouette, flaring outward at the top
  corners so it grows out of the bezel rather than sitting on it.
- Opaque black, always. The panel reads as more bezel, never as a window.
- Idle, Events, Activities and Extensions remain visually flush with the bezel
  and cast no shadow, even when their outline grows horizontally.
- Only Interactions lift off the bezel: Peek and Panel cast the tight contact
  shadow and wide ambient shadow that distinguish a surface you can reach into.

## Layout

- **The notch's own width is dead space.** The camera housing sits over it, so
  content lives in the two flanks and the middle stays empty.
- **The two flanks must read as optically balanced across the housing.** That is
  the rule. Every number below is a means to it, and measured equality is only an
  approximation — two blocks of different width, weight or density need different
  spacing to look evenly set, and the eye is the instrument, not the ruler.
- Each flank has two gaps: the **inner** one against the camera housing, and the
  **outer** one against the bezel. When the two sides hold contents of different
  width, only one of those pairs can be equal. Which one to equalise is the whole
  question, and it is answered per state, by looking:
  - Two contents of similar width — equalise either; they come out the same.
  - Two contents of similar width but different *weight* — equalise the inner
    gaps and let the heavier side sit as it lands.
  - Contents of very different width — the outer edges are usually what the eye
    lines up, so the wider block goes against the housing and the narrower one
    floats.
  - A lone glyph opposite a value — the outer gaps cannot be reconciled at all,
    so equalise the inner ones.
- Three levers reach it, and no others:
  - **Hug** — pin the content to the inner edge, `notchPad` off the housing, and
    let the slack fall outward. The default.
  - **Centre** — split the slack, half against each edge.
  - **Optical correction inside the content** — a fixed box, a rotation, a point
    or two of offset, applied to what the flank holds rather than to the flank
    itself. For ink that does not sit, or does not weigh, what its bounding box
    says: a wide glyph whose terminal is drawn into its own padding, or a thin
    ring opposite a filled icon of the same measured size.
- A flank doing anything other than plain hugging carries one line in the code
  naming what it is balanced against. Without that line the next reader cannot
  tell a calibrated number from a stray one.

## Width

The notch stays as narrow as its content allows. Width is bought, not chosen: a
state that says less grows less. Every pixel past the bezel is borrowed from the
menu bar, so the question is always *what can come out*, never what can fit.

- Say it in the least **ink** that still carries it — measured width, not
  character count. Digits are tabular and pay full width even when they are thin:
  "Full" and "100%" are both four characters, and "Full" is a third narrower.
- A number beats a word **while the number is still moving** — "48°" says more
  than "Cooling down" and costs half the room. At a ceiling there is nothing left
  to measure, and the word is what is left to say. A glyph beats a label.
- **Each side is bought separately.** A flank pays for what it holds, not for
  what the other one holds.
- **Extensions are outboard.** Each buys one mark-wide strip beyond the current
  state's calibrated flank, separated by a hairline — and only then: on an idle
  notch the marks are all there is, so nothing needs separating. The earliest active
  Extension takes the right strip; the next takes the left. The strip is sized
  to the widest mark any of them draws — the VPN word badge, not a plain icon.
- **A lean has to be legible.** Off-centre by a few points reads as a shape that
  failed to line up, not as a decision. A lean worth keeping comes from the two
  sides holding genuinely different things — a whole flank missing, an icon
  opposite a word. One that comes from a percent sign being wider than a degree
  sign is measurement noise, and rounding both to the wider one costs a few
  points and buys back a shape that is obviously on purpose.
- **One live side grows one side.** Nothing to say on the far flank means nothing
  is bought there — the notch leans on purpose, all the way, and the lean is what
  says which subsystem is talking.
- A leaning shape still keeps the notch's own width over the camera housing. The
  extra is spent outward, never by sliding the dead space off the hardware.
- Slack falls outward. Content is already against the housing, so what is left
  over sits between the content and the bezel, where it reads as breathing room.
  A centred flank splits it instead, half against each.
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

- **Events, Activities and Extensions** — horizontal only. The notch stays one
  row tall.
- **Peek** — horizontal, and twice the notch's height. Exact.
- **Panel** — horizontal, and as tall as its body needs: about three notch
  heights. A silhouette, not a measurement. Height is bought the same way width
  is — the shelf and the AirDrop tile set it, and they run a little over three.

## Motion

- Grow and shrink. Never cut, never fade one size into another.
- A state's own numbers changing is not a state change, and must not re-run the
  growth.
