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
- song endings: a song is ended (or, on repeat one, restarted) 0.35 s before the media element finishes, so YouTube's own autoplay never starts a different song first. Endings during ads are ignored.
- a canvas video mode, used for Song/Video switching

There is no equaliser: WebKit hands Web Audio pure silence for YouTube's (Media Source) audio, so routing it through Web Audio filters would only mute it.

The view is kept alive in an off-screen parking window, or mounted in the main window for video.

`PlayerController` owns the queue: radio/autoplay, shuffle, repeat, sleep timer, a persisted queue and counterpart video switching. It also runs crossfade. `WebBridge` keeps a second, muted player page for a song's last 40 seconds (and closes it again); the next song starts there, the two pages swap roles, and a 30 Hz equal-power volume ramp (driven from Swift, since hidden pages' timers are throttled) fades one out and the other in. Smart rules: same album plays straight through, at most a tenth of the song. It also runs the SponsorBlock check and records play stats. `PlaybackClock` extrapolates playback time between polls, which keeps lyrics smooth.

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
| `Feed.swift` | The endless Home/Explore feed: a SwiftUI scroll view whose rows are prepared ahead while you're not scrolling, released far from view (keeping their exact height), and paused during width animations |
| `Components.swift` | Cards (fixed size, so carousels never measure them), shelf carousels, track rows, left-packed grids |
| `PlayerBar.swift` | Player bar, transport, scrubber, volume, crossfade |
| `NowPlayingView.swift` | Now Playing (Lyrics and Artwork views), the lyrics pane, the breathing cover (Core Animation), video host |
| `LockScreenArt.swift` | The lock screen card: a clear window placed above the lock screen through a private window-server space (SkyLight, looked up at run time), shown only while the screen is locked and music plays |
| `QueueAndMini.swift` | Queue inspector, mini player, menu bar player |
| `SignInAndSettings.swift` | Sign-in web view and all settings pages |
| `About.swift` | The About window |

## Preferences and stores

| File | Stores |
| --- | --- |
| `Prefs.swift` | All settings, in `UserDefaults` |
| `Stores.swift` | Sidebar layout, Speed Dial, local play counts and the track-length cache, as JSON in `UserDefaults` |
| `Shortcuts.swift` | Rebindable shortcuts |

## Debugging

- **Frame-pacing log:** run `defaults write local.ytmusicmac perfLog -bool YES` (add `perfLogAll` to count every frame, not just scrolling). The log is written to `~/Library/Containers/local.ytmusicmac/Data/tmp/perf.log`, along with crossfade decisions.
- **Sidebar animation benchmark:** with `perfLog` on, posting the distributed notification `local.ytmusicmac.perf.toggleSidebar` toggles the sidebar and logs the frames of that animation.
- **Launch at an exact window size:** `open build/Encore.app --args -debugWindowSize 1400x900`

## Porting to Windows and Linux

The UI (SwiftUI and AppKit) and playback (WebKit) are Apple-only, so a Windows/Linux version needs a separate front end. The portable parts are:

- the InnerTube requests and parser logic
- lyrics fetching and timing
- the injected player script, which runs in any embedded Chromium or WebKit view

A cross-platform shell such as Tauri (Rust plus a system web view) could reuse the player-script approach directly.
