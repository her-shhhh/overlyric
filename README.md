# Overlyric

A tiny macOS menu-bar app that floats the lyrics of whatever Spotify is playing on top of everything:
the current line and the next one, in big rounded type with a soft shadow, nothing else. Drag it anywhere,
pinch to zoom, pick a colour, toggle it from the menu bar.

```
┌───────────────────────────────────────────────┐
│          I'm running out of time              │   ← current line (solid)
│      'Cause I can see the sun light up        │   ← next line (dimmed)
└───────────────────────────────────────────────┘
```

## Install / run

```bash
./scripts/install.sh        # builds, installs to /Applications, launches
```

Requirements: macOS 14+, Spotify desktop app, Xcode Command Line Tools (Swift 6.2). No Xcode needed.

On first launch macOS asks **“Overlyric wants access to control Spotify”** — click **Allow**. That is what
lets the overlay read the song and the playback position (needed to catch seeks). If you decline, the
overlay still works from Spotify's play/pause/track-change notifications; press play once to sync.

## Using it

Menu bar (top-right, the 🎤 icon):

| Item | What it does |
|---|---|
| **Show Lyrics** | The on/off toggle. The icon dims when off. |
| status lines | What's playing and whether synced lyrics were found. |
| **Lyrics Colour ▸** | 8 presets + *Custom…* (system colour picker, live). |
| **Text Size ▸** | Bigger / Smaller / Reset — or just **pinch** on the lyrics (⌘ + scroll works too). |
| **Lock Position (click-through)** | Freezes the overlay and lets clicks pass through it. |
| **Reset Position** | Back to the bottom-centre of the main screen. |
| **Launch at Login** | Registers with macOS Login Items. |

Drag the lyrics with the mouse to move them. Everything (position, size, colour, on/off) is remembered.

## How it works

- **Spotify state** — `com.spotify.client.PlaybackStateChanged` distributed notifications (instant, no
  permission) for play/pause/track changes, plus a light ScriptingBridge poll every 2 s to catch seeks and
  correct drift. The display is driven by a single one-shot timer armed for the next line boundary — no
  periodic ticking, nothing runs while paused.
- **Lyrics** — [LRCLIB](https://lrclib.net) (free, open, synced LRC). Exact lookups first, then search with
  a duration filter against lrclib's noisy catalogue. Results are cached per track; network failures are
  retried, not cached. Spotify itself has no public lyrics API.
- **Overlay** — a borderless, non-activating `NSPanel` at status-bar level on every Space (incl. full-screen
  apps), sized exactly to the text. Lines are Core Animation layers; a line change animates the old line
  up and out, the next line up into the current slot, and the new next line in from below.

```
Spotify ──notification / SB poll──▶ SpotifyMonitor ──track change──▶ LyricsService (lrclib) ──▶ SyncedLyrics
                                         │                                                        │
                                         └──── position clock ───▶ LyricsController ◀─────────────┘
                                                                        │ (current, next)
                                                                        ▼
                                                    OverlayPanel / OverlayView (CA layers)
```

## Development

```bash
./scripts/test.sh         # unit tests (Swift Testing; needs the framework path flags on CLT-only Macs)
./scripts/build-app.sh    # build/Overlyric.app (ad-hoc signed)
/usr/bin/log stream --predicate 'subsystem == "com.harsh.overlyric"' --level info   # live logs
```

Layout:

```
Sources/OverlyricCore   LRC parser, line window lookup, title/artist cleaning, lrclib matching (pure, tested)
Sources/Overlyric       AppKit app: panel, view, menu, Spotify monitor, lyrics client, controller
Tests/OverlyricCoreTests
docs/ARCHITECTURE.md    design + review findings
```

Gotchas learned the hard way (all documented in `docs/ARCHITECTURE.md`):
`NSAppleScript` deadlocks off the main thread on macOS 26 → ScriptingBridge; `isFloatingPanel` resets the
window level; never add a CAAnimation under the key `"transition"` (it is `kCATransition`, you get a
0.25 s cross-fade of the whole layer for free); ad-hoc signatures re-trigger the Automation prompt after
every rebuild (`OVERLYRIC_SIGN_ID="My Dev Cert" ./scripts/build-app.sh` for a stable identity).
