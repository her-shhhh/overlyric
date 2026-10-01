# Overlyric

*Sing along to anything on Spotify — without knowing a single word.*

**[⬇️ Download the latest version](https://github.com/her-shhhh/overlyric/releases/latest)** — grab the `.dmg`, then open the file called *"Read This or Hum Forever"*.

## How this happened

I always have music on while I work, and a song is twice as good when I can sing along. Today at the
office, in one of those long "Claude is cooking, please wait" breaks, my songs were playing and I couldn't
sing a single line. I never know the words, so it's confident humming and the odd made-up line. And
Spotify's lyrics view would swallow half my tiny laptop screen. So, bored and armed with the shiny new
Ultracode mode on Claude Fable, I thought: let's one-shot a fix. Reader, it was not one shot. It was hours
of very dedicated "work". But Claude built its own karaoke machine for the breaks it gives me, and now the
lyrics float right on my screen. My colleagues are thrilled.

## What it is

A tiny Mac menu-bar app that floats the lyrics of whatever Spotify is playing on top of everything —
big, clean, Instagram-story style, perfectly in time. Only the words show; the rest is see-through.

- **On top of everything**, on every Space and over full-screen apps.
- **Ten lyric styles** — the Instagram ones and a few of our own (below).
- **Colours your way** — pick one, let it pick vivid readable colours from what's behind it, or match
  the album artwork.
- **Drag** the lyrics anywhere (right up to the screen edges), **⌘ + scroll** on them to resize,
  **click** them to jump to Spotify, **right-click** for the menu.
- No Spotify login, no account, no subscription, no nonsense.

## For friends: install

1. Open **Overlyric-x.y.z.dmg** (and the file called **"Read This or Hum Forever"** — it's short). Drag
   **Overlyric** onto **Applications**. Don't double-click it inside the DMG window: macOS won't remember
   your approval there and keeps asking.
2. Open Overlyric from Applications. The first time, macOS blocks apps that aren't from the App Store or
   a registered developer:
   - **macOS 15 Sequoia / 26 Tahoe:** click **Done** (not *Move to Bin*), then open **System Settings ›
     Privacy & Security**, scroll to the **Security** section and click **Open Anyway** next to Overlyric
     (within about an hour). macOS asks once more: click **Open** and enter your Mac login password.
   - **macOS 14 Sonoma:** Control-click Overlyric › **Open** › **Open**.
3. Look for the **🎤 mic icon in the menu bar** (top right — on a notched MacBook it may hide behind the
   notch if your menu bar is full). There's no Dock icon; everything lives in that menu. The same menu
   also opens when you **right-click the lyrics**, or when you open Overlyric again while it's running.
4. Play a song in the **Spotify desktop app**. The first time, click **Allow** when macOS asks whether
   Overlyric may control Spotify — that's how it reads the song and its position.

Requirements: macOS 14 or later (Apple Silicon or Intel) and the Spotify desktop app.

### About the warnings (why they appear, and why it's fine)

- **"Apple could not verify Overlyric is free of malware"** — macOS says this about every app that isn't
  from the App Store or from a developer in Apple's paid ($99/year) programme. It isn't a scan result;
  Apple simply hasn't reviewed it. You approve it once.
- **"Overlyric wants access to control Spotify"** — macOS words this broadly for any app that talks to
  another app. Overlyric only asks Spotify which song is playing and how far in it is. It never touches
  your account, playlists or likes (only exception: clicking the "encore?" offer restarts that song).
- **"Screen Recording"** (only if you turn on Lyrics Colour › Auto) — it looks at a tiny patch right
  behind the lyrics to pick a readable colour. Nothing is saved or sent; the purple menu-bar dot is macOS
  showing you when it looks.
- **What it connects to:** lrclib.net for lyrics, and Spotify's image server for the album cover if you
  choose "Match album artwork". No login, no account, no tracking, no ads.
- **The menu-bar microphone is just a logo.** Overlyric never uses your real microphone (it would need your
  permission, and it never asks).
- On macOS 15 and later, Auto colour's Screen Recording permission may re-ask about once a month
  ("bypass the system private window picker") — same tiny patch; allow it or switch Auto off.
- **To remove it:** quit it from the microphone menu and drag it from Applications to the Bin.

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
| **Read This or Hum Forever…** | Opens the guide: the story, the setup and every control, any time. |

### Styles

| Style | What it looks like |
|---|---|
| **Jump** *(default)* | Words jump up into place as they're sung. |
| **Two Lines** | The line being sung, and the next one waiting underneath. |
| **One Line** | Just the line being sung. |
| **Scrolling Lyrics** | The whole song drifting slowly upwards, the current line lit (Instagram's teleprompter). |
| **Typewriter** | Types itself out as it's sung, in a typewriter face. |
| **Karaoke** | Each line lights up left to right as it's sung. |
| **Dynamic** | Big billboard rows of mixed sizes, words popping in as they're sung. |
| **Pop** | One word at a time, flashing on as it's sung. |
| **Glide** | Lyrics glide right to left like a ticker. |
| **Cube** | Lines roll over like the faces of a cube. |

### Colours

- **Auto** reads a tiny patch of the screen behind the lyrics and picks a fresh, vivid colour that's
  clearly readable on it — bright colours on dark screens, deep ones on light screens — from the whole
  spectrum. It changes only when the background makes the current colour hard to read, or when the song
  changes. macOS asks for **Screen Recording** permission the first time you turn it on (and only then):
  allow it in System Settings, then click the Auto status line in the menu to reopen Overlyric — macOS
  only applies the permission to a freshly opened app. It never asks again by itself, and the grant
  survives updates. The purple screen-capture dot in the menu bar appears briefly when it samples.
- **Match album artwork** uses the cover's theme colour, brightened for reading.
- Out of the box the lyrics are **Lemon** yellow; the presets, Custom… and Auto are in Lyrics Colour.

## Easter eggs

A few small surprises are switched on by default — hold **⌥ (Option)** while the menu is open to find
the switch.

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

## License

MIT — see [LICENSE](LICENSE). Fork it, remix it, send a pull request; just keep the copyright notice.
