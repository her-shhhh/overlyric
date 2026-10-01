# Overlyric — Architecture & Design (v0.1, 2026-10-01 — updated after build + reviews)

## Goal
A macOS menu-bar app that overlays the synced lyrics of the song currently playing in Spotify
on top of everything on screen: two lines at a time (current + next), transparent background,
only the text is solid, draggable anywhere, pinch-to-zoom live, colour selectable, toggled from
a menu-bar (top-right) status item.

## Non-goals (v0.1)
No Spotify login/OAuth, no lyrics editing, no word-level karaoke highlight, no Windows/Linux.

## Platform / toolchain
- macOS 14+ (dev machine: macOS 26.5.2, Apple Silicon), Swift 6.2, SwiftPM (Command Line Tools only, no Xcode).
- Pure AppKit (no SwiftUI) for predictable window-level / gesture behaviour.
- Build: `swift build -c release` → `scripts/build-app.sh` assembles `Overlyric.app`
  (Info.plist: LSUIElement=true, NSAppleEventsUsageDescription, CFBundleIdentifier com.harsh.overlyric),
  ad-hoc codesign, install to /Applications (fallback ~/Applications), launch via `open`.

## Data flow
```
Spotify.app ──(DistributedNotification com.spotify.client.PlaybackStateChanged)──┐
Spotify.app ──(AppleScript poll every ~2s: state, position, track id/name/artist/album/duration)──┤
                                                                                                  ▼
                                                                                   SpotifyMonitor (state model)
                                                                                                  │ track change
                                                                                                  ▼
                                                                    LyricsService (LRCLIB client + cache) ──► SyncedLyrics
                                                                                                  │
                                                                              LyricsController (100 ms display tick)
                                                                                                  │ (current,next) line change
                                                                                                  ▼
                                                                                   OverlayPanel / OverlayView (AppKit)
StatusMenuController (NSStatusItem) ──► Settings (UserDefaults) ──► OverlayView / Controller
```

## Components
### SpotifyMonitor
- State: `track {id,name,artist,album,durationMs}?`, `isPlaying`, `position`, `positionTimestamp`.
  `extrapolatedPosition(now) = isPlaying ? position + (now - positionTimestamp) : position`.
- Source A (push, no permission): `DistributedNotificationCenter` name `com.spotify.client.PlaybackStateChanged`
  userInfo keys (to be verified empirically): "Track ID", "Name", "Artist", "Album", "Duration"(ms),
  "Player State" ("Playing"/"Paused"/"Stopped"), "Playback Position"(s).
- Source B (poll, needs Automation TCC permission, prompts once): compiled `NSAppleScript`
  `tell application "Spotify"` → player state, player position, current track fields. Runs on a
  dedicated serial background queue so a TCC prompt or a slow Spotify never blocks the UI.
  Only runs when Spotify is running (checked with NSRunningApplication, never launches Spotify).
  Poll interval 2 s while enabled & playing; 5 s while paused; stops when overlay disabled.
  If the AppleScript is denied (-1743) we keep notification-only mode and tell the user in the menu
  ("press play/pause once to sync").
- Drift rule: if |polled - extrapolated| > 0.5 s, snap to polled.
- Spotify quit (NSWorkspace.didTerminateApplicationNotification) → clear state, hide overlay.

### LyricsService (LRCLIB)
- `GET https://lrclib.net/api/get?track_name&artist_name&album_name&duration` (exact match)
  → fallback `GET /api/get` without album → fallback `/api/search?track_name&artist_name` choose
  result with `syncedLyrics != null` and |duration - ours| ≤ 3 s (else closest) → fallback with
  cleaned title (strip " - Remastered…", "(feat. …)", "[…]").
- Required `User-Agent: Overlyric/0.1 (https://github.com/…)`.
- Per-track in-memory cache incl. negative results (per app session). Request coalescing: a newer
  track cancels/ignores an in-flight older fetch (generation counter).
- Parse `syncedLyrics` (LRC): `[mm:ss.xx]`/`[mm:ss.xxx]`, multiple tags per line, empty text = ♪ gap,
  sorted by time. `plainLyrics`-only tracks are treated as "no synced lyrics" (we cannot time them).

### LyricsController
- Owns display tick (100 ms, `.common` run-loop mode, only while enabled AND Spotify state known).
- Computes `(currentIdx, nextIdx)` via binary search on line times; pushes to the view only when
  the pair changes (so redraws ≈ once per lyric line).
- States shown by the overlay: lines / "♪" (gap before first line or instrumental) /
  dim small "No synced lyrics for this track" / hidden (Spotify not running or stopped or disabled).

### OverlayPanel (NSPanel)
- styleMask [.borderless, .nonactivatingPanel]; isOpaque=false; backgroundColor=.clear; hasShadow=false;
  level=.statusBar; collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary];
  hidesOnDeactivate=false; isFloatingPanel=true; isMovableByWindowBackground=true; ignoresMouseEvents toggle.
- Sized-to-content: the window rect is exactly the text block + 14 pt padding, re-laid-out around a
  fixed centre whenever text or zoom changes. Therefore no transparent dead-zone can swallow clicks.
- Drag: mouseDown → `performDrag(with:)`; frame persisted on windowDidMove.
- Pinch: `magnify(with:)` → fontSize *= (1+magnification), clamped 14…160 pt, live, persisted on gesture end.
- Lock/click-through: menu toggle sets `ignoresMouseEvents = true`.

### OverlayView (design — Instagram-story lyric look, "very neat")
- Type: SF Rounded, heavy weight for current line, semibold for next; centered; tight leading;
  slight negative tracking. Wrap width = clamp(fontSize × 16, 320, 0.8 × screen width).
- Current line: chosen colour @100 %; next line: same colour @ 55 % and 0.85 × size.
- Legibility over any background: soft shadow (black 55 %, radius ≈ fontSize/6, offset y −1) — no boxes.
- Line change animation (250 ms, ease-out): next line slides up into the current slot while brightening,
  new next line fades in from below, old current line fades out upward. Implemented with layer-backed
  NSTextField labels + NSAnimationContext. Zoom changes are applied without animation (live).
- "♪" glyph for gaps. Dim small italic status line for "no lyrics".

### StatusMenuController (NSStatusItem, top-right menu bar)
Menu: [✓] Show Lyrics · status line (track / "Spotify not running") · Colour ▸ (8 presets + Custom…
via NSColorPanel) · Text Size ▸ (Bigger ⌘+, Smaller ⌘−, Reset) · [ ] Lock position (click-through) ·
Reset Position · [ ] Launch at Login (SMAppService) · Quit.
Icon: SF Symbol "music.mic" (full when ON, 40 % alpha when OFF).

### Settings (UserDefaults)
enabled(true), fontSize(34), colorRGBA(white), clickThrough(false), windowOrigin(bottom-centre, 120 pt up), launchAtLogin(false).

## Threading
Main: AppKit, controller, timers, state application. Background serial queue: AppleScript polling.
URLSession completion → hop to main. All state mutation on main.

## Failure handling
| Failure | Behaviour |
|---|---|
| Spotify not installed/running | Overlay hidden; menu status says so. |
| Automation permission denied | Notification-only mode; menu says "press play/pause once to sync". |
| No synced lyrics | Dim "No synced lyrics" line; cached negative for the session. |
| Network down | Same as no lyrics; retried on next track change. |
| Window off-screen after display change | Re-clamped to visible frame on show. |

## Test plan
- Unit (swift test): LRC parser (formats, multi-tag, ms precision, empty lines, ordering), sync index
  lookup (before first, between, after last, exact boundary), title cleaning, LRCLIB JSON decoding,
  position extrapolation (playing/paused).
- Integration (QA agent on this Mac): build+bundle+sign+launch; drive Spotify via AppleScript to a
  known track with synced lyrics; confirm overlay window exists at expected level (CGWindowList);
  screenshot; toggle off/on from menu; colour change persists after relaunch; pinch simulated via
  menu zoom; lock toggle; Spotify quit hides overlay.


---

## What changed during the build (verified on this Mac, macOS 26.5)

1. **NSAppleScript off the main thread hangs** (AESendMessage never returns, nondeterministic). Replaced with
   **ScriptingBridge KVC reads** on a serial queue, targeting the Spotify *pid* (never launches Spotify).
   `playerState` is an NSNumber four-char code (`kPSP`/`kPSp`/`kPSS`); `duration` is ms; position is float32 s.
2. **Spotify posts no notification on seek** and no heartbeat — only play/pause/track change. Hence the
   light poll (state + position, ~16 ms) every 2 s, full read (+track) at start / on disagreement / every 10th.
3. **No periodic display tick.** A one-shot timer fires exactly at the next line boundary and is re-armed on
   every snapshot change. Idle cost is zero while paused or hidden.
4. **Overlay is a layer-hosting view of CALayers** (not NSTextFields): AppKit label animations were not smooth
   enough. Each line is drawn with AppKit text into its own layer; transitions animate position / scale /
   opacity on the compositor (0.5 s, ease-out). The next line is rendered at full size and scaled by a
   transform so its rise into the current slot is a continuous scale-up of an identical bitmap.
5. **`isFloatingPanel = true` resets `level`** — set the level afterwards.
6. **`performDrag(with:)` is a no-op** for a non-key panel of an inactive app; `isMovableByWindowBackground`
   + `mouseDownCanMoveWindow` is what actually drags the window.
7. **Pinch delivery** to an inactive app's non-key panel is not guaranteed by AppKit docs (the archived
   gesture guide says gestures go "to the active application"). Three paths cover every routing:
   `NSMagnificationGestureRecognizer` on the view (if the system routes the pinch to the window under the
   pointer), a global `.magnify` monitor (NSEvent.h: global monitors receive copies of events posted to
   *other* applications; only key events need Accessibility) that zooms when the pointer is over the lyrics,
   and ⌘+scroll. The menu also has a live slider (14–160 pt) for precise sizing.
8. **Never add a CAAnimation under the key `"transition"`.** That is `kCATransition`: CA then cross-fades
   the layer's whole previous rendering with the new one, which looked like a doubled, ghosted line.
9. **Implicit actions** are disabled on line layers (`action(forKey:) → nil`), otherwise a redraw
   cross-fades old and new text.
10. **Window sizing is anchored on the user's chosen centre** (not the current frame centre), so clamping at
    a screen edge never ratchets the overlay away from the edge; padding grows with font size so the shadow
    and the rising/fading lines are not clipped by the window bounds.
11. **lrclib**: exact `/api/get` has a ±2 s duration window and no fuzzy matching; `/api/search` is BM25 with
    heavy pollution, so a 3-tier duration filter (≤2 s, ≤5 s, ≤15 s + exact normalised title) picks the record;
    requests are sequential (250 ms spacing), 429/503 honour Retry-After; transport/decode failures are
    surfaced (`.failed`, retried later) rather than cached as "no lyrics"; superseded fetches are cancelled.
12. **Ad-hoc signing** binds the TCC Automation grant to the cdhash → each rebuild re-prompts once. Use
    `OVERLYRIC_SIGN_ID` with a self-signed code-signing certificate for a stable identity.
13. UserDefaults keys are prefixed (`overlyric.*`); the first builds' unprefixed keys are migrated once.
