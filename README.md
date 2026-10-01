# Overlyric

Sing along to anything on Spotify. Overlyric floats the lyrics of the song that's playing on top of
everything on your Mac — big, clean, Instagram-story style — and keeps them perfectly in time.

- **On top of everything**, on every Space and over full-screen apps; only the words are visible.
- **Ten lyric styles** — the Instagram ones and a few of our own (below).
- **Colours your way** — pick one, let it pick vivid readable colours from what's behind it, or match
  the album artwork.
- **Drag** the lyrics anywhere (right up to the screen edges), **⌘ + scroll** on them to resize,
  **click** them to jump to Spotify.
- No Spotify login, no account, no API keys.

## For friends: install

1. Open **Overlyric-x.y.z.dmg** and drag **Overlyric** onto **Applications**.
2. Open Overlyric from Applications. The first time, macOS blocks apps that aren't from the App Store or
   a registered developer:
   - **macOS 15 Sequoia / 26 Tahoe:** click **Done**, then open **System Settings › Privacy & Security**,
     scroll down and click **Open Anyway** next to Overlyric (within an hour), and confirm.
   - **macOS 14 Sonoma:** Control-click Overlyric › **Open** › **Open**.
3. Look for the **🎤 mic icon in the menu bar** (top right — on a notched MacBook it may hide behind the
   notch if your menu bar is full). There's no Dock icon; everything lives in that menu.
4. Play a song in the **Spotify desktop app**. The first time, click **Allow** when macOS asks whether
   Overlyric may control Spotify — that's how it reads the song and its position.

Requirements: macOS 14 or later (Apple Silicon or Intel) and the Spotify desktop app.

## The menu

| Item | What it does |
|---|---|
| **Show Lyrics** | Turns the overlay on or off (the icon dims when off). |
| status lines | What's playing and whether synced lyrics were found. |
| **Lyrics Style ▸** | Ten styles (below). |
| **Lyrics Colour ▸** | **Auto** (colourful, always readable on what's behind), **Match album artwork**, 8 presets, or **Custom…** |
| **Text Size ▸** | A live slider (14–160 pt), Bigger / Smaller / Reset. Or hold **⌘** and scroll on the lyrics. |
| **Lock Position (click-through)** | Freezes the overlay and lets clicks pass through to what's underneath. |
| **Reset Position** | Back to the bottom-centre of the screen. |
| **Launch at Login** | Starts Overlyric when you log in (needs the app in Applications). |

### Styles

| Style | What it looks like |
|---|---|
| **Two Lines** | The line being sung, and the next one waiting underneath. |
| **One Line** | Just the line being sung. |
| **Scrolling Lyrics** | The whole song drifting slowly upwards, the current line lit (Instagram's teleprompter). |
| **Typewriter** | Types itself out as it's sung, in a typewriter face. |
| **Karaoke** | Each line lights up left to right as it's sung. |
| **Dynamic** | Big billboard rows of mixed sizes, words popping in as they're sung. |
| **Pop** | One word at a time, flashing on as it's sung. |
| **Jump** | Words jump up into place as they're sung. |
| **Glide** | Lyrics glide right to left like a ticker. |
| **Cube** | Lines roll over like the faces of a cube. |

### Colours

- **Auto** reads a tiny patch of the screen behind the lyrics and picks a fresh, vivid colour that's
  clearly readable on it — bright colours on dark screens, deep ones on light screens — from the whole
  spectrum. It changes only when the background makes the current colour hard to read, or when the song
  changes. macOS asks for **Screen Recording** permission the first time you turn it on (and only then);
  the purple screen-capture dot in the menu bar appears briefly when it samples.
- **Match album artwork** uses the cover's theme colour, brightened for reading.

## Where do the lyrics come from?

From [LRCLIB](https://lrclib.net), a free, open database of time-synced lyrics (Spotify doesn't let
other apps use its own lyrics). Most popular songs are there, including lots of Hindi and other
non-English songs; if a song has no synced lyrics you'll see a small note instead. Lyrics are cached
on your Mac, so a song is only ever looked up once. Overlyric sends nothing else anywhere.

## Development

```bash
./scripts/test.sh         # unit tests (Swift Testing; Command Line Tools are enough)
./scripts/build-app.sh    # build/Overlyric.app (native arch, ad-hoc signed)
./scripts/install.sh      # build, copy to /Applications, launch
./scripts/release.sh      # universal (Apple Silicon + Intel) app in dist/Overlyric-<version>.dmg
/usr/bin/log stream --predicate 'subsystem == "com.harsh.overlyric"' --level info   # live logs
```

```
Sources/OverlyricCore    pure, unit-tested logic: LRC parsing, line lookup, lrclib matching, colour
                         choice, artwork colour, shake detection, lyrics disk cache
Sources/Overlyric        the app: menu, overlay panel + host view, Spotify monitor, lyrics service,
                         background sampler, easter eggs, onboarding
  Styles/                one renderer per lyric style on a shared Core Animation toolkit
Tests/OverlyricCoreTests
docs/ARCHITECTURE.md     how it works, and the macOS gotchas we hit
```
