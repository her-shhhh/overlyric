# Overlyric — status (as of 2026-10-02, version 1.1.4)

## 1.1.4 (2026-10-02)
- Fresh installs start in **Dynamic** style with **Yellow** lyrics (a new vivid preset); both are first in
  their menus (Jump and Lemon moved to second).
- **Welcome song:** the very first launch plays Coldplay's "Yellow" once (`Onboarding.takeFirstSong`, key
  `overlyric.firstSongPlayed`). Opens Spotify in the background if it isn't running, waits up to 10 min for
  the Automation grant, then sends `play track` and re-sends (3 s apart, max 6) until Spotify reports it
  playing. The guide and README say so. Verified live on the dev Mac (upgrade from 1.1.3): played on the first
  try, "Yellow" playing ~1 s later with its 49 synced lines.

## 1.1.3 (2026-10-02)
- Story in the guide and README no longer carries the friends-only Anuv Jain inside joke (the guide gets shared
  beyond the original friend group); replaced with a line anyone gets.

## 1.1.2 (2026-10-02)
- Menu › **Read This or Hum Forever…** opens the guide in its own designed window (app icon + title, real
  headings, gold bullets/numbers, bold quoted warnings, light/dark, "Let's sing" + "View on GitHub"). It typesets
  the same text that ships as the DMG's .txt (bundled by `scripts/render-readme.sh`, parsed by
  `GuideDocument` in Core, tested). Verified by offscreen renders; not yet clicked live.

## 1.1.1 (2026-10-02)
- Fresh installs start in **Jump** style with **Lemon** lyrics; both are first in their menus.
- Friends' read-me rewritten story-first and quirky, renamed **"Read This or Hum Forever.txt"**; text lives in
  `Resources/friends-readme.txt` (release.sh fills in version / min macOS); the GitHub README opens with the
  same story.

## 1.1.0 (2026-10-02)
- Friends' read-me (in the DMG) and README open with a plain-language "About the warnings" section: why
  Gatekeeper / "control Spotify" / Screen Recording prompts appear, exactly what the app does and connects to
  (lrclib.net; Spotify's image server for artwork mode), how to remove it. Read-me no longer suggests
  double-clicking inside the DMG.
- lrclib User-Agent now reports the real app version.

## Friend-install dry run (2026-10-02, on the dev Mac with app/settings/permissions wiped)
- Gatekeeper: "Apple could not verify … free of malware" → Done → Open Anyway (expected without notarization).
- **In-DMG Gatekeeper loop (re-confirmed 2026-10-02 ~01:45):** double-clicking Overlyric **inside the mounted
  DMG window** shows "“Overlyric” Not Opened — Apple could not verify…" with only a **Done** button, every
  time, even after an earlier Open Anyway: Gatekeeper approval doesn't stick for an app run from a read-only
  disk image (each launch is translocated again). Harsh got stuck in this loop.
  **Reliable path:** drag Overlyric from the DMG window onto Applications → open it from /Applications →
  Done → System Settings › Privacy & Security › **Open Anyway** (once). The move offer below only helps on a
  launch from the DMG that Gatekeeper lets through.
- The friends' read-me (now `Read This or Hum Forever.txt`, from `Resources/friends-readme.txt`) tells
  people to drag to Applications and never double-click inside the DMG window.
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
- Live, 2026-10-02 (0.1.2, quarantined "downloaded" DMG): drag to Applications → blocked once → Open Anyway →
  runs from /Applications; approval sticks (user-approved quarantine bit), lyrics load, Auto colour works.
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
2. **Package for friends to avoid the in-DMG loop:** shipping a .zip was offered and declined (keep the DMG).
   Remaining free option: a styled DMG with a big drag-to-Applications arrow (dmgbuild, no Finder
   scripting); notarization (decision 1) removes the problem entirely.
3. Version number for the friends release (0.1.x → 1.0.0?).

## Known polish items (from QA, not applied)
- Two Lines: outgoing line disappears in ~65 ms (needs window headroom during a change to scroll away).
- Two Lines: if a sung line is skipped (0→2) the dim preview vanishes in one frame.
- One Line / Two Lines: a change < 0.1 s after the previous one cuts the still-fading line.
- Minor sub-pixel softness in Dynamic word layers; minor timing nuances in Scroll/Glide/Pop/Jump.
- Cube QA agent failed (content filter); Cube was reviewed manually from offscreen frames only.
