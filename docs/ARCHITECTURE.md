# Overlyric — architecture

A macOS menu-bar app (Swift 6.2, SwiftPM, AppKit + Core Animation; builds with the Command Line Tools
alone) that floats the synced lyrics of the song playing in the Spotify desktop app above everything.

## Data flow

```
Spotify.app ── PlaybackStateChanged notification (play/pause/track; no permission) ──┐
Spotify.app ── ScriptingBridge reads on a serial queue (state+position every 2 s) ────┤
                                                                                       ▼
                                                                         SpotifyMonitor (PlaybackSnapshot)
                                                                                       │ track change
                                                                                       ▼
                                          LyricsService: memory cache → disk cache → lrclib.net (get → search)
                                                                                       │ SyncedLyrics
                                                                                       ▼
            LyricsController: PlaybackClock + current line → StyleContent; one timer per line boundary
                                                                                       │
                                                                                       ▼
          OverlayView (host: sizing, mouse gate, drag/click/⌘-scroll) → StyleRenderer (one per style)
                                                                                       ▲
     StatusMenuController · Settings (UserDefaults) · BackgroundSampler (Auto colour) · EasterEggs
```

## Modules

**OverlyricCore** (pure Foundation, unit-tested): LRC parser (multiple tags, word tags stripped, BOM,
offsets, equal timestamps merged), `SyncedLyrics` (binary-search current line), `TrackNameCleaner` and
`LyricsMatcher` (lrclib's normalisation, 3-tier duration matching), `ContrastChooser` (WCAG maths and the
readable random colour generator), `ArtworkColor`, `ShakeDetector`, `LyricsDiskCache`.

**Spotify** — `SpotifyMonitor` merges the push notification with ScriptingBridge polls (light poll: state +
position; full poll: + track; escalates once on any disagreement). Spotify posts no notification on seek,
so the light poll catches seeks and drift (> 0.4 s). Reads target Spotify's pid so they can never launch it.

**Lyrics** — `LyricsService` tries exact `/api/get` variants then `/api/search`, sequentially with 250 ms
spacing, honouring 429/503 Retry-After, 15 s per request. Results go to memory and to
`~/Library/Caches/com.harsh.overlyric/lyrics` (found lyrics forever, "not found" for 2 days). Network
failures are retried by the controller at 3, 8, 20, 45 and 90 s while the song plays (♪ meanwhile).

**Timing** — no periodic tick. The controller arms one timer for the next line boundary (or the encore
window) and re-arms on every state change. A `PlaybackClock` maps Spotify time to `CACurrentMediaTime`, so
time-driven styles (typewriter, karaoke sweep, word pops, drift, ticker) run as Core Animation timelines on
the compositor; pause/seek re-time them (`retime`).

**Overlay** — `OverlayPanel`: borderless non-activating `NSPanel`, level `.statusBar`, on all Spaces and
over full-screen apps, never key, sized exactly to the text plus padding for shadows and transitions.
It is anchored at its top-centre (lines wrap downwards), clamped so the *text* can reach the left, right and
bottom screen edges but never covers the menu bar. `OverlayView` is layer-hosting; it owns the current
renderer, keeps the window at max(old, new) size during a line change and shrinks it after, and runs a
**mouse gate**: the window takes the mouse only while the pointer is over the words (global mouse-moved
monitor + tracking area), so the transparent padding is click-through. Click = open Spotify; drag
(manual tracking loop) = move; ⌘ + scroll = resize. Lock = everything click-through.

**Styles** (`Styles/`) — `StyleRenderer` protocol + `BaseRenderer` toolkit. A renderer's root layer has
its origin at the top-centre of the text block (bounds origin trick), so resizing never shifts what is
drawn. `TextLayout` wraps TextKit and reports geometry from typeset positions. Styles: Two Lines, One
Line, Scrolling (teleprompter), Typewriter, Karaoke (sweep), Dynamic (billboard rows), Pop, Jump,
Glide, Cube.

**Colour** — Manual, **Auto** (`BackgroundSampler`: one-shot ScreenCaptureKit captures of the region behind
the window, excluding it; median per-pixel luminance decides bright vs deep text with hysteresis; colours
are generated from the whole spectrum and kept while readable; re-sampled on app/Space switches, window
stack changes behind the lyrics (cheap CGWindowList check), moves, and every 4 s while playing; never
captures without a grant), or **Artwork** (dominant vivid hue of the cover, brightened). Colour changes
"dip": the stage fades to a low opacity, the colour swaps, and it fades back (a `CATransition` snapshot
would double moving lyrics).

**Easter eggs** — sparkle words (stars/rain/fire/love/snow → particle flourish), shake the lyrics while
dragging, the third play in a row, and an encore offer after the last line. Hold ⌥ with the menu open —
"Launch at Login" turns into the Easter Eggs switch.

**Onboarding** — first launch shows a one-time hello in the overlay; running from a disk image or App
Translocation offers to move the app to /Applications: it copies itself there (or reuses an identical
version), clears the quarantine flag on the installed copy, relaunches from there and ejects the source DMG.

## Mouse & menu

Right-click / Control-click on the lyrics opens the same menu as the menu-bar icon (useful when the icon
hides behind the notch). Opening Overlyric while it already runs hands off to the running copy and quits.

## QA harness

`tools/style-harness/run.sh [out]` compiles the real renderers with a mini host and renders every style
offscreen through CARenderer (no windows, no permissions): Latin advance, wrapping Hindi advance, into/out
of an instrumental gap, progress through a line, and pause (asserts two paused frames are identical).
Strips land in `/tmp/overlyric-style-frames` (one PNG per style × scenario). Rule learned the hard way:
attach the layer tree to the CARenderer *before* triggering a transition — committing animations on a
detached tree completes them instantly.

## macOS gotchas (all hit and verified on macOS 26)

- `NSAppleScript` deadlocks off the main thread → ScriptingBridge on a serial queue.
- `isFloatingPanel = true` resets `level`; set the level after it.
- `performDrag(with:)` does nothing for a never-key panel of an inactive app → manual tracking loop.
- Trackpad pinch (magnify) events are never delivered to a background overlay (only to the active app;
  global monitors don't see them) → ⌘ + scroll and a menu slider instead.
- Never add a `CAAnimation` under the key `"transition"` (it is `kCATransition`: a whole-layer cross-fade).
  Disable implicit actions on every layer we own, including `sublayers` on the root.
- Glyph bounding boxes are ~3× too wide for Devanagari; use line-fragment used rects and glyph locations.
- An explicitly set `ignoresMouseEvents = false` makes the transparent padding swallow clicks → mouse gate.
- `CGPreflightScreenCaptureAccess` is cached per process; a grant made while running needs a reopen. Any
  capture attempt without a grant can re-show the system dialog → never capture without a grant.
- macOS keys permissions on the designated requirement; the default ad-hoc one is the build hash, so every
  build silently loses its grants → ad-hoc sign with `designated => identifier "com.harsh.overlyric"`.
- `swift build --arch arm64 --arch x86_64` needs Xcode → build each triple and `lipo` (scripts/release.sh).
- XCTest isn't in the Command Line Tools; Swift Testing is, with explicit framework flags (scripts/test.sh).
