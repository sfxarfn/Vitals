# Now Playing as the panel's second feature page

**Status:** Done — 2026-10-19
**Why:** The user wanted Now Playing in the notch. Every comparable notch app
(boring.notch, Atoll, mew-notch, DynamicNotch) reads it through
ungive/mediaremote-adapter, because macOS 15.4 took the MediaRemote
entitlement from third-party apps and Apple-signed `/usr/bin/perl` still has it.

## Phase 1 — proved on this Mac first
- Cloned ungive/mediaremote-adapter @ `0e82bf1` (2026-10-17) into the session
  scratchpad. BSD 3-Clause: bundling is allowed with the copyright notice kept.
- Built from source with `clang`, using the same flags as its `CMakeLists.txt`
  (no CMake on this Mac), and ad-hoc signed it. No binary was downloaded.
- On macOS 27.0.1 (Mac15,12), with a Safari video:
  - `test` exited 0.
  - `get` returned title, artist, duration, elapsed time, `playing`,
    `parentApplicationBundleIdentifier` (Safari) and JPEG artwork.
  - `stream` printed a full snapshot, then diffs.
  - `send 2` (toggle play/pause), with the user's OK, started and stopped
    the video, and the stream reported `playing` true, then false.
- Also checked: perl loads the library from a `MediaRemoteAdapter.framework`
  folder holding just the binary, unzipped from the bundled zip — the layout
  the app builds at runtime.

## What changed
- `tools/build-mediaremote-adapter.sh` — rebuilds the adapter from the pinned
  commit with clang and codesign, and writes the vendored files.
- `Vitals/Interactions/MediaRemoteAdapter/` — `MediaRemoteAdapter.zip` (the
  universal arm64/x86_64 library, zipped), `mediaremote-adapter.pl`, and
  `MediaRemoteAdapter-LICENSE.txt` (BSD licence plus the source commit).
  Zipped because Xcode recognises a Mach-O by its contents: shipped first as
  `MediaRemoteAdapter.dat`, it was linked into `Vitals.debug.dylib`
  (`@rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter`), never copied,
  and dyld aborted at launch. A zip is only a resource. `project.pbxproj`
  needed no build phase.
- `Vitals/Interactions/NowPlaying.swift` — `@Observable @MainActor` service.
  - At runtime it unzips the library with `ditto` into
    `~/Library/Caches/<bundle id>/MediaRemoteAdapter.framework/`, fresh on
    every launch so an updated app never runs an old library; the ad-hoc
    signature survives the zip.
  - It runs `perl … stream --debounce=100` only while the panel is open. The
    last snapshot is kept, so the page has something to show straight away.
  - Diffs are folded into the last full payload (a null removes the key).
    Artwork is decoded only when it arrives.
  - A stream that dies while the panel is open restarts after 1s. Three deaths
    inside 30s switch to AppleScript for the rest of the session.
  - Commands use `perl … send 2/4/5` (play/pause, next, previous), and the
    play/pause button flips straight away.
  - The AppleScript fallback polls Music and Spotify every 2s through
    `/usr/bin/osascript`, and only asks apps that are already running. Going
    through osascript means Vitals needs no Apple Events entitlement under the
    hardened runtime.
- `Vitals/Interactions/NowPlayingPage.swift` — the page:
  - 56pt rounded artwork that opens the player app, with a note glyph until
    the artwork arrives.
  - Semibold title and secondary artist.
  - A progress hairline that ticks every second while playing.
  - Previous, play/pause and next buttons in `VitalsPressStyle`.
  - Empty state: "Nothing playing" with a music note.
- `PanelView.swift` — `PanelPage` is now `nowPlaying, shelf`: Now Playing is
  the main page, and with two cases the arrows go live and the dots appear on
  their own. `openingPage` is the one place that picks the page each open:
  Shelf if a file drag opened the panel or the shelf already holds files,
  otherwise Now Playing. `resetPanelSlot()` applies it (no detail) when the
  panel opens and when it closes, so the last page is never remembered across
  opens; within one open the arrows page freely. A drag entering an open
  panel still flips to Shelf (`showShelf()`), including over a detail.
- `NotchController.swift` / `NotchView.swift` — `nowPlaying` is owned by the
  controller and passed in. `grow` and `shrink` set `nowPlaying.active`.
- `project.pbxproj` — `INFOPLIST_KEY_NSAppleEventsUsageDescription` in both
  Debug and Release, for the fallback's Automation prompt.
- `README.md` — a Now Playing note under "Grant permissions" (no prompt
  normally; one Automation prompt per app only if the fallback kicks in).
- `.ai/README.md` — code map rows for the service, the page and the vendored
  adapter.

## Verification
- Adapter: run and confirmed on this Mac, as above. The vendored zip,
  unzipped with `ditto` into a `.framework` folder, keeps its ad-hoc
  signature and returns the same `get` output.
- App code: not built or run here (project rule). After building, check:
  - Hovering with an empty shelf opens on Now Playing, with title, artist,
    artwork and a moving progress line; the arrows are bright and the right
    arrow goes to Shelf.
  - Hovering with files in the shelf opens on Shelf; dragging a file to the
    notch opens on Shelf; dragging a file over Now Playing switches to Shelf.
  - Play/pause, next and previous work. Clicking the artwork opens the player
    (Safari for a web video).
  - With nothing playing, the page says "Nothing playing".
  - Closing the panel ends the perl process (`pgrep -fl mediaremote-adapter`
    should be empty with the notch idle).
  - Closing and reopening does not remember the page: it is chosen again.
  - Do **Product → Clean Build Folder** first: the earlier `.dat` build left
    the adapter linked into `Vitals.debug.dylib`. Afterwards
    `otool -L Vitals.app/Contents/MacOS/Vitals.debug.dylib | grep -i mediaremote`
    is empty, Vitals launches, and `Contents/Resources/` holds
    `MediaRemoteAdapter.zip` and `mediaremote-adapter.pl`.

## Notes
- No code from boring.notch or Atoll (GPL v3). Only the adapter, under its own
  BSD licence.
- The AppleScript fallback has no artwork, and it only knows Music and Spotify.
- If a future macOS removes perl's entitlement, the adapter dies on start and
  the fallback takes over after three tries (about 3s).

## Follow-up: making the page feel alive — 2026-10-19
The page read as dead: a grey tile and still text whatever was playing.
- `NowPlaying.swift` — `artworkTint`: the cover's average colour, from the
  image drawn into a 1×1 context and lifted so dark sleeves still tint.
  Re-sampled only when the artwork object changes.
- `NowPlayingPage.swift`
  - The tile is washed with the cover's colour from the artwork side and
    cross-fades between tracks. It has the cursor-following hover light.
  - While playing the artwork is full size with a soft glow in its own
    colour. Paused, it steps back to 0.9 and dims, on a spring.
  - Three equaliser bars beside the title move while playing and lie flat
    when paused. They are not real levels, which MediaRemoteAdapter does not
    publish.
  - A new track slides its title and artist up into place.
  - The progress line takes the cover's colour and glides between half-second
    ticks.
  - Play/pause morphs between the two glyphs; previous and next bounce on the
    tap (`skipBounce`/`backBounce` in `NotchView`).
  - Reduce Motion keeps the colour and drops the scale, bars, slide and
    bounce.
- Pending after building: play something with colourful artwork. Check the
  tile takes its colour, the bars move, pausing shrinks and dims the cover and
  flattens the bars, skipping slides the new title in and bounces the button,
  and the progress line moves smoothly.

## Follow-up: layout A, skips hidden in the times — 2026-10-19
- `NowPlayingPage.swift`
  - Top row: 42pt artwork, title and artist, and one 20pt play/pause button.
    The design said about 46pt; 42 + 5 + 18 + 2×6 fills the 77pt slot
    exactly. The separate prev/next buttons are gone.
  - Bottom row: elapsed time, the progress line, and remaining time ("-2:21"),
    11pt with monospaced digits at white 0.6, all on one twice-a-second clock.
  - The times are the skip buttons (`TimeSkipButton`). Hovering one
    cross-fades it into `backward.end.fill` / `forward.end.fill` (track skip, not the fast-forward `backward.fill` / `forward.fill`) in 0.15s with a slight
    scale, and a click sends previous or next. The time and the glyph share one
    34×18pt box, so the line never changes width. `VitalsPressStyle(scales:
    false)`; `.help` "Previous"/"Next"; accessibility labels "Previous track" /
    "Next track". Reduce Motion swaps without animating.
  - With no duration (a live stream) no times show. The two arrows stay in
    place, dimmed, so skipping is still possible.
  - Unchanged: the cover-colour wash, the pause dim and shrink, the equaliser,
    the title slide, and the play/pause morph and skip bounce.
- Pending after building: hover each time and see it turn into an arrow that
  skips; the line stays the same width; a radio or live stream shows dimmed
  arrows and no times; everything fits the tile without clipping.

## Follow-up: idle → panel lag — 2026-10-19
Opening the panel lagged again once Now Playing became the first page. Each
of these ran on the main thread during the grow:
- The first open unzipped the adapter with `ditto` and waited for it.
  `NowPlaying.init` now does that on a background queue at launch.
  `framework` and `script` are `nonisolated` statics.
- Perl was spawned straight away. `start()` now waits 0.4s, until the grow
  has settled, and the kept snapshot fills the page meanwhile.
- The first `stream` line, about 340 KB of base64 artwork, was JSON-parsed,
  decoded into a full image and colour-sampled on the main thread. Lines are
  now split (`LineBuffer`), parsed and decoded (`parse` → `StreamLine`) on the
  pipe's queue. Only the small result reaches the main thread (`apply`),
  without the artwork bytes.
- The page drew the full 1280-wide cover into a 42pt box on every frame. The
  cover is now a 128px thumbnail from ImageIO, made off the main thread, and
  the tint is sampled from that thumbnail.
- Pending after building: idle → panel feels as smooth as before Now Playing
  existed, including the first open after launch; the page fills in within
  about half a second; artwork still looks sharp at 42pt.

## Superseded — stream lifecycle (2026-10-19)
The stream no longer runs only while the panel is open, and the 0.4s delayed
start is gone. One stream runs for the life of the app to feed the
track-change pill; see `track-change-pill.md` for the measured cost and the
details.
