# Encore

**A native macOS client for YouTube Music**, with an Apple Music–style interface, Liquid Glass, karaoke-style synced lyrics and full macOS media integration.

> **Unofficial.** Encore is an independent open-source project. It is not affiliated with, endorsed by or sponsored by Google, YouTube or Apple. "YouTube" and "YouTube Music" are trademarks of Google LLC. You need your own YouTube Music account; Premium is respected (ad-free, higher-quality audio).

![Now Playing](docs/screenshots/nowplaying.jpg)

| Artist | Album |
| --- | --- |
| ![Artist page](docs/screenshots/artist.jpg) | ![Album page](docs/screenshots/album.jpg) |

| Search | Settings |
| --- | --- |
| ![Search](docs/screenshots/search.jpg) | ![Appearance settings](docs/screenshots/settings.jpg) |

<sub>Screenshots were taken signed out with sample content. Artwork and artist names belong to their respective owners.</sub>

## Features

- **Native SwiftUI app.** Sidebar, artwork grids, album, playlist and artist pages, a rich search page with live suggestions, Home sections you can hide, and a Speed Dial of your pinned items plus recently played songs.
- **Endless Home and Explore.** After YouTube's own sections run out, Encore keeps adding "Because you listened to…" sections. Pull down at the top to refresh.
- **Now Playing.** Full-window player with an artwork-coloured animated background that reacts to your cursor, Song/Video switching (HD video), and an Up Next list.
  - Lyrics view: the cover beside the lyrics, or beside Up Next when a song has none.
  - Artwork view: just the cover, big, breathing slowly (animated by Core Animation, so it costs almost no CPU).
- **Lock screen player.** While music plays, a Liquid Glass media card (cover, song, wavy progress line in the cover's colour, controls) sits on the lock screen. Click the cover and the art fills the screen; click again to go back. You can turn it off.
- **Desktop widgets.** Now Playing (small, medium, large: cover colours, live progress, play controls, Up Next) and Cover (just the artwork).
- **Uploads.** Your uploaded songs, albums and artists in the Library, and uploading more: drop audio files on the page or choose Upload Music (MP3, M4A, FLAC, OGG, WMA).
- **Synced lyrics.** Word-by-word karaoke highlighting, using Better Lyrics word timings, LRCLIB line timings, or YouTube Music's own lyrics.
- **Queue.** Reorder, remove, shuffle, repeat and autoplay ("radio"), plus a play history. Repeat one loops without a gap.
- **Updates.** Check for Updates in the app menu and in Settings › General. Updates download from GitHub, are checked against the release signing key, replace the old version and reopen. Automatic checks and installs are on by default (right away, after a day or a week, or every 2–3 versions).
- **Crossfade.** The next song starts on a second player and plays over the end of the current one (Off to 12 seconds), with a Smart mode that plays albums straight through. Repeat one crossfades back into the start. The second player only exists for a song's last 40 seconds.
- **macOS integration.** Media keys, Now Playing and Control Center, AirPods controls, a Dock menu, a menu bar player, a floating mini player, a sleep timer and playback speed.
- **Customisation.**
  - Light/dark appearance, any accent colour, and a Liquid Glass / Frosted / Solid look with adjustable transparency.
  - A resizable, reorderable sidebar.
  - Rebindable keyboard shortcuts.
- **Your own extensions.** Small JavaScript files that react to songs and control the player (skip short tracks, post songs to a webhook, night-time volume…), run in their own engine with a limited API. Add, import, edit and switch them in Settings › Extensions.
- **Built-in extensions.**
  - SponsorBlock skips non-music sections of music videos.
  - Auto-skip for songs you've disliked.

## Requirements

- A Mac with **Apple Silicon** (M1 or later)
- **macOS 14 Sonoma or later.** The Liquid Glass look needs macOS 26; earlier versions fall back to frosted glass.
- A YouTube Music (Google) account

## Install

1. Download the latest `Encore-x.y.z-macOS-arm64.zip` from [Releases](../../releases) and unzip it.
2. Move **Encore.app** to your Applications folder.
3. The app isn't notarised by Apple yet, so the first time, **right-click → Open** (or run `xattr -dr com.apple.quarantine /Applications/Encore.app`).
4. Click **Sign In** and sign in on Google's own page.

## Build from source

You need Xcode 16 or later (Xcode 26 for the Liquid Glass APIs) or the matching Swift toolchain.

```bash
git clone <this repository>
cd encore
./build.sh --run        # builds build/Encore.app and opens it
./build.sh --install    # copies it to /Applications
```

| Command | Result |
| --- | --- |
| `APP_NAME="Something Else" ./build.sh` | Builds under a different app name. |
| `scripts/package.sh` | Builds a release zip in `dist/`. |

You can also open `Package.swift` in Xcode.

## How it works

| Part | What it does |
| --- | --- |
| Interface | SwiftUI. The karaoke lyrics are drawn with Core Animation (`UI/KaraokeLayer.swift`). |
| Library and search | YouTube Music's InnerTube JSON API (`Core/InnerTube.swift`, `Core/Parser.swift`), authenticated with your signed-in session. The parser skips anything it doesn't recognise, so a change on Google's side breaks one section, not the app. |
| Playback | A hidden `WKWebView` runs music.youtube.com, and Encore drives YouTube's own player (`Core/WebBridge.swift`). Stream deciphering, Premium quality and DRM stay in Google's code. |
| Lyrics | Better Lyrics (word-synced TTML), then LRCLIB, then YouTube Music (`Core/Lyrics.swift`). |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for more.

## Privacy and security

- You sign in on Google's own page. **Encore never sees or stores your password.**
- It runs in the **App Sandbox** with the **hardened runtime**, and may only make outgoing network connections. Your session cookies stay in the app's private container.
- All traffic is HTTPS. The player and sign-in views block non-HTTPS and non-Google pages.
- **Sign Out** wipes all cookies, website data and the saved queue.
- There's no analytics or telemetry. Third-party services see only what they need:
  - **Lyrics lookups** send the song title, artist, album and length.
  - **SponsorBlock** receives only the first 4 characters of a hash of the video ID.

## Limitations

- Encore is unofficial, so a change to music.youtube.com can break something until it's updated.
- There are no offline downloads: YouTube restricts downloads to its own apps.
- There's no built-in equaliser: Apple's web engine doesn't let apps process YouTube's audio stream. A system-wide equaliser app still works.
- **macOS and Apple Silicon only, for now.** See [Roadmap](#roadmap).

## Roadmap

- Developer ID signing and notarisation, so the app opens without a warning
- An Intel / Universal build
- **Windows and Linux.** The app is built on SwiftUI, AppKit and WebKit, which only exist on Apple platforms, so other platforms need a separate front end. The plan is a cross-platform app (for example Tauri), reusing the same design and the same InnerTube and lyrics logic.

## Credits

- Lyric timing behaviour is modelled on Better Lyrics and [ytm-rs](https://github.com/grapedjuice/ytm-rs). It was reimplemented from scratch, and no code was copied.
- Lyrics data comes from Better Lyrics and [LRCLIB](https://lrclib.net).
- Segment data comes from [SponsorBlock](https://sponsor.ajay.app).

## License

[MIT](LICENSE)
