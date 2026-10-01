# Overlyric — status (as of 2026-10-02, version 0.1.2)

## Friend-install dry run (2026-10-02, on the dev Mac with app/settings/permissions wiped)
- Gatekeeper: "Apple could not verify … free of malware" → Done → Open Anyway (expected without notarization).
- **In-DMG Gatekeeper loop (re-confirmed 2026-10-02 ~01:45):** double-clicking Overlyric **inside the mounted
  DMG window** shows "“Overlyric” Not Opened — Apple could not verify…" with only a **Done** button, every
  time, even after an earlier Open Anyway: Gatekeeper approval doesn't stick for an app run from a read-only
  disk image (each launch is translocated again). Harsh got stuck in this loop.
  **Reliable path:** drag Overlyric from the DMG window onto Applications → open it from /Applications →
  Done → System Settings › Privacy & Security › **Open Anyway** (once). The move offer below only helps on a
  launch from the DMG that Gatekeeper lets through.
- The DMG's `Read me first.txt` (written by `scripts/release.sh`) still suggests "just double-click Overlyric
  here" as an alternative to dragging — that leads into the loop; remove it in the next release.
- **Bug (fixed in 0.1.1/0.1.2, not yet re-tested live):** "Move to Applications" copied the app WITH its
  quarantine flag, so the relaunched copy was blocked/translocated and nothing ran; "Not Now" worked. Now the
  installed copy has the flag cleared, an identical-version copy is reused, the app relaunches after the old
  process exits, and the source DMG is ejected — also in the normal downloaded case where macOS runs a
  translocated copy (0.1.2 finds the mounted volume carrying the same app + version).

## Shipped in 0.1.0
- 10 lyric styles: Two Lines, One Line, Scrolling (teleprompter), Typewriter, Karaoke, Dynamic, Pop, Jump,
  Glide, Cube.
- Colour: fixed / presets / Custom, **Auto** (random vivid colours that stay readable on what's behind;
  Screen Recording), **Match album artwork**.
- Drag anywhere (text may touch screen edges, never the menu bar), ⌘ + scroll to resize, Text Size slider,
  click → opens Spotify, right-click → menu, transparent padding is click-through, Lock (click-through).
- Lyrics from lrclib.net with disk cache and automatic retries; no Spotify login.
- Easter eggs (sparkle words, shake, on repeat, encore) behind the ⌥ menu switch.
- Onboarding: one-time welcome note; offer to move to /Applications when run from a DMG/translocation.
- `scripts/release.sh` → universal (arm64 + x86_64) `dist/Overlyric-<version>.dmg`, ad-hoc signed with a
  stable designated requirement (permissions survive updates).

## Verified
- 50 unit tests (Core). Offscreen frame-by-frame QA of every style (tools/style-harness): no blockers or
  majors; pause freezes exactly in every style.
- Live, 2026-10-02 (0.1.1, downloaded-DMG install): Auto colour end-to-end — Screen Recording granted, colour
  flips bright↔deep with fresh random hues as dark/light windows pass behind the lyrics.
- Live on macOS 26 (earlier builds): sync, track change, seek, pause/play, Spotify quit/relaunch, drag,
  ⌘-scroll, click → Spotify, Hindi lyrics, ~0.5 % CPU while playing.

## Not yet verified
- Final installed build live with music playing (Spotify was paused during the last pass).
- Live: right-click menu, Artwork colour, easter eggs (sparkles, on repeat, encore), Launch at Login.
- Fresh-Mac first run (Gatekeeper → Open Anyway, move-to-Applications offer, welcome), the Intel slice at
  runtime, macOS 14/15.

## Open decisions
1. **Gatekeeper warning** ("Apple could not verify … free of malware") appears for every non-notarized
   download. Options: (a) Developer ID + notarization — needs an Apple Developer account ($99/yr, or a
   Developer ID cert from an existing team); `release.sh` already supports `OVERLYRIC_SIGN_ID` +
   `NOTARY_PROFILE`; (b) free one-line Terminal installer (curl-downloaded files aren't quarantined → no
   warning) — needs a public download URL; (c) both.
2. **Package for friends to avoid the in-DMG loop:** (a) ship a .zip instead of a DMG (Safari auto-extracts
   to Downloads, a writable place, so Open Anyway sticks and the app's own "Move to Applications" offer
   finishes the install) or (b) a styled DMG with a big drag-to-Applications arrow (dmgbuild, no Finder
   scripting); notarization (decision 1) removes the problem entirely.
3. Version number for the friends release (0.1.x → 1.0.0?).

## Known polish items (from QA, not applied)
- Two Lines: outgoing line disappears in ~65 ms (needs window headroom during a change to scroll away).
- Two Lines: if a sung line is skipped (0→2) the dim preview vanishes in one frame.
- One Line / Two Lines: a change < 0.1 s after the previous one cuts the still-fading line.
- Minor sub-pixel softness in Dynamic word layers; minor timing nuances in Scroll/Glide/Pop/Jump.
- Cube QA agent failed (content filter); Cube was reviewed manually from offscreen frames only.
