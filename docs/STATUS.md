# Overlyric — status (as of 2026-10-02, version 0.1.1)

## Friend-install dry run (2026-10-02, on the dev Mac with app/settings/permissions wiped)
- Gatekeeper: "Apple could not verify … free of malware" → Done → Open Anyway (expected without notarization).
- Opening Overlyric **from inside the mounted DMG** keeps re-showing the block (approval can't be recorded on a
  read-only image) → users must drag it to Applications first, or use the move offer below.
- **Bug (fixed in 0.1.1, not yet re-tested live):** "Move to Applications" copied the app WITH its quarantine
  flag, so the relaunched copy was blocked/translocated and nothing ran; "Not Now" worked. 0.1.1 clears the
  flag on the installed copy, reuses an identical-version copy, relaunches after the old process exits and
  ejects the DMG.

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
- Live on macOS 26 (earlier builds): sync, track change, seek, pause/play, Spotify quit/relaunch, drag,
  ⌘-scroll, click → Spotify, Hindi lyrics, ~0.5 % CPU while playing.

## Not yet verified
- Final installed build live with music playing (Spotify was paused during the last pass).
- Live: right-click menu, Auto colour end-to-end (grant → reopen → switching dark/light windows), Artwork
  colour, easter eggs (sparkles, on repeat, encore), Launch at Login.
- Fresh-Mac first run (Gatekeeper → Open Anyway, move-to-Applications offer, welcome), the Intel slice at
  runtime, macOS 14/15.

## Open decisions
- **Gatekeeper warning** ("Apple could not verify … free of malware") appears for every non-notarized
  download. Options: (a) Developer ID + notarization — needs an Apple Developer account ($99/yr, or a
  Developer ID cert from an existing team); `release.sh` already supports `OVERLYRIC_SIGN_ID` +
  `NOTARY_PROFILE`; (b) free one-line Terminal installer (curl-downloaded files aren't quarantined → no
  warning) — needs a public download URL; (c) both.
- **Styled DMG window** (background arrow, icon layout) — free; build the Finder layout without scripting
  Finder (e.g. dmgbuild) so no permission prompts.
- Version number for the friends release (0.1.0 → 1.0.0?).

## Known polish items (from QA, not applied)
- Two Lines: outgoing line disappears in ~65 ms (needs window headroom during a change to scroll away).
- Two Lines: if a sung line is skipped (0→2) the dim preview vanishes in one frame.
- One Line / Two Lines: a change < 0.1 s after the previous one cuts the still-fading line.
- Minor sub-pixel softness in Dynamic word layers; minor timing nuances in Scroll/Glide/Pop/Jump.
- Cube QA agent failed (content filter); Cube was reviewed manually from offscreen frames only.
