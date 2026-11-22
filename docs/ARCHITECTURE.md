# Architecture

Encore is a Swift Package (`Package.swift`) with one executable target. `build.sh` wraps the binary into a sandboxed `.app`, using `Resources/Info.plist` and `Resources/Encore.entitlements`.

```
Sources/Encore/
  App/    entry point, scenes, app model, Dock icon
  Core/   networking, parsing, playback, lyrics, preferences, stores
  UI/     SwiftUI views and styles
```

## Playback (`Core/WebBridge.swift`, `Core/Player.swift`)

A hidden `WKWebView` loads music.youtube.com with your session. An injected script (`window.__ytmac`) exposes:

- player state
- load, play, pause, seek, volume and playback rate
- HD selection and volume fades
- the Web Audio equaliser
- a canvas video mode, used for Song/Video switching

The view is kept alive in an off-screen parking window, or mounted in the main window for video.

`PlayerController` owns the queue: radio/autoplay, shuffle, repeat, sleep timer, a persisted queue and counterpart video switching. It also runs the SponsorBlock check and records play stats. `PlaybackClock` extrapolates playback time between polls, which keeps lyrics smooth.

## Data (`Core/InnerTube.swift`, `Core/Parser.swift`, `Core/JSON.swift`)

Library, search and browse requests go to InnerTube's JSON API over `URLSession`, using the web view's cookies and a `SAPISIDHASH` authorisation header. `JSON` is a tolerant, dynamic-member wrapper. `Parser` turns renderers into `MediaItem`, `Track`, `Shelf` and page models, and ignores anything it doesn't recognise.

`music/get_queue` fills in track lengths that list responses leave out (`DurationCache` in `Core/Stores.swift`).

## Lyrics (`Core/Lyrics.swift`, `UI/KaraokeLayer.swift`)

Sources, in order:

1. Better Lyrics word-synced TTML, parsed by `TTMLParser`
2. LRCLIB line-synced LRC
3. YouTube Music's own plain lyrics

Each line is laid out with Core Text into a bitmap and animated with one `CALayer` per letter. Each word has a gradient sweep mask, the letters lift as they are sung, long-held words swell, and each word gets a fading glow.

Timing defaults follow Better Lyrics:

| Setting | Value |
| --- | --- |
| Lead | 150 ms (word-synced) / 115 ms (line-synced) |
| Sweep | 1.6 × word duration, starting 10% early |
| Line scale | 0.95 → 1 over 166 ms |
| Scroll curve | cubic-bezier(0.86, 0, 0.2, 1) over 750 ms |

## Interface (`UI/`)

| File | Contents |
| --- | --- |
| `ContentView.swift` | Window layout: animated background, resizable sidebar, detail pane, queue, floating top bar and player bar, search panel, Now Playing overlay |
| `Theme.swift` | Glass panels (Liquid Glass on macOS 26, frosted or solid otherwise), button styles, the ambient artwork background, window chrome (traffic-light placement) |
| `Pages.swift` | Home, Explore and browse shelves; collection (album/playlist) pages built on a native `List` for fast scrolling; artist, library and search pages |
| `Components.swift` | Cards, shelf carousels, track rows |
| `PlayerBar.swift` | Player bar, transport, scrubber, volume |
| `NowPlayingView.swift` | Now Playing, the lyrics pane, video host |
| `QueueAndMini.swift` | Queue inspector, mini player, menu bar player |
| `SignInAndSettings.swift` | Sign-in web view and all settings pages |

## Preferences and stores

| File | Stores |
| --- | --- |
| `Prefs.swift` | All settings, in `UserDefaults` |
| `Stores.swift` | Sidebar layout, Speed Dial, local play counts and the track-length cache, as JSON in `UserDefaults` |
| `Shortcuts.swift` | Rebindable shortcuts |

## Debugging

- **Frame-pacing log:** run `defaults write local.ytmusicmac perfLog -bool YES`. The log is written to `~/Library/Containers/local.ytmusicmac/Data/tmp/perf.log`.
- **Launch at an exact window size:** `open build/Encore.app --args -debugWindowSize 1400x900`

## Porting to Windows and Linux

The UI (SwiftUI and AppKit) and playback (WebKit) are Apple-only, so a Windows/Linux version needs a separate front end. The portable parts are:

- the InnerTube requests and parser logic
- lyrics fetching and timing
- the injected player script, which runs in any embedded Chromium or WebKit view

A cross-platform shell such as Tauri (Rust plus a system web view) could reuse the player-script approach directly.
