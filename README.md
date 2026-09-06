# MPVPlayerKit

English | [简体中文](README.zh-CN.md)

An iOS 15+ Swift Package that wraps [MPVKit](https://github.com/mpvkit/MPVKit) with a small UIKit API.

## Features

- HTTP and local video playback
- Play, pause, stop, exact seek and playback-rate control
- Hardware decoding with automatic fallback from VideoToolbox to software
- HDR and Dolby Vision playback with EDR-aware Metal output
- Audio, video and subtitle track discovery and selection
- Framework-owned SRT/VTT parsing, timing, styling and default rendering
- Replaceable client subtitle renderer for custom application UI
- External ASS/SSA loading through MPV with original-style support
- Subtitle delay, style presets and per-instance custom fonts
- Picture in Picture for custom and quick-player interfaces
- Now Playing controls on the lock screen and in Control Center
- Memory buffer configuration with 10/30/60/120 second durations
- Full-screen pan gestures for seeking, brightness and volume, each individually disableable
- Forced landscape that also works when the host app declares only portrait support
- A reusable rendering view for custom player interfaces
- An optional ready-to-present `MPVQuickPlayerViewController`

## Requirements

- iOS 15.0 or later
- Swift 6 toolchain (the package builds with swift-tools 6.0 in the Swift 6 language mode)
- [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0, pinned exactly
- Rendering runs on a custom `CAMetalLayer`; EDR output requires iOS 16 or later on a device that supports it

## Installation

After publishing the package, add its repository URL in Xcode through **File > Add Package Dependencies**. The package product is `MPVPlayerKit`.

For a local checkout, add the `MPVPlayerKit` directory as a local package dependency.

## Custom player interface

Use `MPVPlayer` when the app already has its own controls:

```swift
import MPVPlayerKit

let configuration = MPVPlayerConfiguration(
    url: videoURL,
    headers: ["Authorization": "Bearer token"],
    userAgent: "ExampleApp/1.0"
)
let player = MPVPlayer(configuration: configuration)

containerView.addSubview(player.playbackView)
player.playbackView.frame = containerView.bounds
player.play()

player.seek(to: 120, autoPlay: true)
player.startPictureInPicture()

let audioTracks = player.tracks(ofType: .audio)
if let track = audioTracks.first {
    player.select(track: track)
}

let subtitleTracks = player.tracks(ofType: .subtitle)
if let subtitle = subtitleTracks.first {
    player.select(track: subtitle)
}
```

`MPVPlayerConfiguration` accepts:

| Field | Purpose |
| --- | --- |
| `url` | Local file or HTTP(S) media URL |
| `headers` | Extra HTTP request headers forwarded to mpv (`Authorization` and `X-Emby-Authorization` are deliberately not forwarded) |
| `userAgent` | Custom HTTP user agent |
| `forceSoftwareDecode` | Skips the hardware decoding paths |
| `isDolbyVisionPlayback` | Hints the pipeline that the stream is Dolby Vision |
| `videoQuality` | Rendering preset, see [Video quality](#video-quality) |
| `debandEnabled` | Enables debanding |
| `cacheConfiguration` | Memory buffer settings, see [Cache](#cache) |

The display mode of `player.playbackView` follows `player.contentMode`, mapping aspect-fit and aspect-fill onto mpv's fit and fill modes.

Set `MPVPlayer.delegate` to receive updates; every method has a default empty implementation:

```swift
public protocol MPVPlayerDelegate: AnyObject {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState)
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval)
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int)
    func player(_ player: MPVPlayer, didUpdateBufferedProgress progress: Int?)
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode)
    func player(_ player: MPVPlayer, didChangePictureInPictureActive isActive: Bool)
}
```

`MPVPlaybackState` reports `buffering`, `readyToPlay`, `bufferFinished`, `paused`, `playedToTheEnd` and `error`. `MPVPlayer.bufferedProgress` and `didUpdateBufferedProgress` report a 0...100 percentage when both the media duration and mpv cache position are available; otherwise the value is `nil`.

## Playback engine

### Decoding

Hardware decoding tries `videotoolbox` first, falls back to `videotoolbox-copy`, and then to software decoding when a profile fails on the first playback attempt. The Simulator always decodes in software. Set `forceSoftwareDecode: true` in the configuration to skip the hardware paths. The active mode is reported through `didUpdateDecoderMode` (`initializing`, `hardware`, `software`).

### Video quality

`MPVVideoQuality` selects a rendering preset:

- `.powerSaving` — bilinear scalers, no dithering, no sigmoid upscaling.
- `.balanced` (default) — lanczos upscaling, mitchell downscaling.
- `.highQuality` — `ewa_lanczossharp` upscaling with sigmoid upscaling, correct downscaling and dithering for the best detail retention.

Debanding is toggled through `updateVideoRenderOptions(debandEnabled:)` and is forced off in the `.powerSaving` preset.

### HDR and Dolby Vision

The Metal layer switches between SDR output (`bgra8Unorm_srgb`, sRGB color space) and EDR output (`rgba16Float`, extended linear sRGB) depending on the target screen's EDR headroom. Tone mapping stays with mpv, so HDR and Dolby Vision content is neither clipped nor double-mapped. The Simulator and iOS 15 devices remain in SDR.

### Seek and progress

`seek(to:autoPlay:)` issues mpv's absolute exact seek. The target position is published optimistically — consecutive seeks and remote-command skips stay in sync — and rolls back if mpv rejects the command. Seeking while paused refreshes the displayed frame. Time and duration are polled twice a second and delivered through `didUpdateCurrentTime`.

### Buffering

State transitions are driven by a pure state machine (`MPVBufferingStateMachine`) that observes mpv's `paused-for-cache`, cache-buffering-state, idle and end-of-file properties, with a fallback timer for streams that never report buffering state.

### Cache

`MPVCacheConfiguration(isEnabled:duration:)` configures mpv's demuxer memory buffer. Supported durations are 10, 30, 60, and 120 seconds (default 30).

## Picture in Picture

Picture in Picture is available through `startPictureInPicture()`,
`stopPictureInPicture()`, and `togglePictureInPicture()`. The built-in quick
player starts Picture in Picture only after its button is tapped, and
activates a playback audio session first. Hosts that
explicitly opt into background-initiated Picture in Picture may set
`allowsAutomaticPictureInPictureFromInline`; this requires the Audio, AirPlay,
and Picture in Picture background mode.

Picture in Picture uses the video-call content source: the inline
`MPVPlayerView` itself is moved into the system window and moved back on exit,
so mpv keeps rendering through its own Metal pipeline — subtitles, tone mapping,
the fit/fill mode and the full frame rate all carry over unchanged. No frame
capture is involved.

- The window is shaped like the video: its content size follows the display
  aspect ratio MPV reports, so anamorphic video is not stretched and the shape
  of the inline container never leaks into the window.
- On exit the player view is restored to its original inline hierarchy and
  playback continues seamlessly.
- `isPictureInPictureSupported` reports whether the system offers Picture in
  Picture (and the coordinator was created); `isPictureInPictureActive` mirrors
  the current state, also delivered through `didChangePictureInPictureActive`.

Playback position, rate and skip handling are published to the Now Playing
controls on the lock screen and in Control Center; see
[System media controls](#system-media-controls).

## System media controls

The built-in coordinator publishes `MPNowPlayingInfoCenter` — the title comes
from the URL's last path component, alongside elapsed time, playback rate, and
the duration (or a live-stream marker when the duration is unknown) — and
registers `MPRemoteCommandCenter` handlers for play, pause, toggle play/pause,
skip backward and forward (15 second interval) and `changePlaybackPosition`.

Hosts that drive their own Remote Command Center can opt out with
`playerView.systemPlaybackControlsEnabled = false`.

## Client-rendered subtitles

SRT and WebVTT files loaded without original styling use the framework subtitle
pipeline. `MPVSubtitleDocument` handles UTF-8, UTF-16 and GB18030 text, normalizes
embedded ASS overrides, and provides time-based cue lookup. The built-in
`MPVDefaultSubtitleRenderer` is installed automatically:

```swift
player.loadClientSubtitle(from: subtitleURL) { success in
    print("Subtitle loaded:", success)
}
```

Applications can supply their own renderer while leaving parsing and timing in
the framework:

```swift
@MainActor
final class AppSubtitleRenderer: MPVSubtitleRenderer {
    let view = UIView()

    func render(_ presentation: MPVSubtitlePresentation) {
        // Render presentation.cues using the application's own UI.
    }

    func clear() {
        // Remove the current subtitle.
    }
}

player.useClientSubtitleRenderer(AppSubtitleRenderer())
```

## Subtitle fonts

Noto remains the default subtitle font bundled by MPVPlayerKit. Applications can
register a local font file for the current player instance; the font is not
added to the package:

```swift
try player.setSubtitleFont(from: fontFileURL)

switch player.currentSubtitleFontCapability {
case .noSubtitle:
    break
case .unsupported:
    // Image subtitles such as SUP/PGS/VobSub cannot use a font.
    break
case .supported:
    break
}

player.resetSubtitleFont()
```

`setSubtitleFont(from:)` throws `MPVSubtitleFontError` when the URL is not a
local font file or registration fails. The same API and capability property are
available through `MPVQuickPlayerViewController`; custom subtitle renderers can
read `MPVSubtitleStyle.fontName` from their presentation.

`MPVQuickPlayerViewController` uses the same pipeline through its public
`player`, so its external SRT/VTT picker works without application-side subtitle
layers.

## Quick player interface

For apps that do not need custom controls:

```swift
let playerViewController = MPVQuickPlayerViewController(
    url: videoURL,
    forceLandscape: true
)
present(playerViewController, animated: true)
```

Playback starts automatically when the view appears unless `autoplay` is set to `false`. The quick interface provides play/pause, seeking, time display, a Picture in Picture button that enters and leaves the window, video/audio/subtitle track selection, external subtitle loading and cancellation, subtitle delay and style presets, playback speed, video quality, debanding, memory buffer settings, fit/fill display modes, decoder and buffering status, forced-landscape control, and a centered loading indicator. Its compact control bar uses system icons with accessibility labels. Forced landscape also works when the host app declares only portrait support: the quick player rotates its own content when system-level scene rotation is unavailable.

Landscape lock can also be changed while the player is visible:

```swift
playerViewController.setForceLandscape(true)
```

On iOS 16 or later the rotation goes through scene geometry updates; on iOS 15 the orientation is forced directly. When the host app declares portrait support only, the quick player rotates its own content — kept in sync with presented view controllers, alerts excepted — so forced landscape still works.

### Gestures

A single tap toggles the top and bottom control layers. Three full-screen pan gestures are built in:

- **Horizontal drag** — scrubbing. A full-screen-wide drag covers 10% of the media duration (clamped to 60–600 seconds); the seek is applied once when the finger is released, with a HUD showing the direction, the target time and a progress bar.
- **Vertical drag on the left half** — screen brightness, with a percentage HUD.
- **Vertical drag on the right half** — system volume, adjusted through a hidden `MPVolumeView`.

Each gesture can be disabled when the host app owns that interaction:

```swift
playerViewController.gestureOptions = [.seeking, .volume]
```

`MPVQuickPlayerGestureOptions` is an `OptionSet` with `.seeking`, `.brightness`, `.volume` and `.all` (the default). An empty set keeps only the tap.

### Programmatic settings

Settings can also be changed programmatically through `setPlaybackRate` (clamped to 0.25...4.0), `setVideoQuality`, `setDebandEnabled`, `setCacheConfiguration`, `setSubtitleDelay` (clamped to ±60 seconds), and `setSubtitleStyle`. `MPVCacheConfiguration` supports 10, 30, 60, and 120 second memory buffer durations. The quick player's cache settings are persisted as app-local global preferences and reused by later quick-player instances. The underlying `player` remains public for direct access to every `MPVPlayer` operation.

It is optional; `MPVPlayer` does not depend on it at runtime.

## Objective-C bridge

`MPVPlayerView` exposes its full surface to Objective-C through `@objc` members, for hosts that build their own playback engine on top of it — including hosts that load the class through the Objective-C runtime and drive it with `NSDictionary` options:

- Setup and playback: `configure(_:)` (URL, headers, user agent, decoding, quality, deband and cache options), `play()`, `pause()`, `stop()`, `seek(_:)`, `updatePlayRate(_:)`
- Tracks and subtitles: `mediaTracks(_:)`, `selectTrack(_:)`, `loadSubtitle(_:)`, `cancelSubtitleLoad(_:)`, `setSubtitleVisible(_:)`, `updateSubtitleStyle(_:)`, `updateSubtitleDelay(_:)`, `setSubtitleFontFromURL(_:)`, `resetSubtitleFontFromBridge()`, `currentSubtitleText()`
- Rendering and layout: `playerContentModeRawValue`, `prepareLayoutTransition(_:)`, `refreshLayout(_:)`, `beginDisplayGeometryTransition()`, `endDisplayGeometryTransition()`
- Picture in Picture: `isPictureInPictureSupported`, `isPictureInPictureActive`, `startPictureInPicture()`, `stopPictureInPicture()`, `togglePictureInPicture()`, `allowsAutomaticPictureInPictureFromInline`
- System controls: `systemPlaybackControlsEnabled`

State changes are also broadcast as `NSNotification` objects: `MPVPlayerViewDidChangeState`, `MPVPlayerViewDidUpdateTime`, `MPVPlayerViewDidUpdateBufferingProgress`, `MPVPlayerViewDidUpdateBufferedProgress`, `MPVPlayerViewDidUpdateDecoderMode`, `MPVPlayerViewDidLoadSubtitle`, `MPVPlayerViewDidCompleteSeek` and `MPVPlayerViewDidChangePictureInPicture`.

## Demo

Open `Demo/MPVPlayerKitDemo.xcodeproj` and run the `MPVPlayerKitDemo` scheme. The Demo references this checkout as a local Swift Package and launches the quick player with a public HLS sample. Replace `sampleURL` in `Demo/MPVPlayerKitDemo/AppDelegate.swift` to test media with custom audio or subtitle tracks.

## Notes

- MPVKit is pinned to the `1.0.0` release so the native runtime and its transitive binary dependencies remain reproducible.
- The package is distributed as a dynamic library so MPVKit's native runtime stays isolated from an app's other media dependencies.
- The bundled Noto fonts are used for consistent multilingual subtitle rendering. Their original license files are included under `Resources`.
- Not included (yet): loop/repeat playback, a long-press playback-rate gesture, double-tap gestures, a screen-lock gesture, screenshot or recording APIs, and a player-level volume API — the quick player's volume gesture adjusts the system volume.

## License

This package's source code is available under the MIT License. MPVKit is an LGPL-3.0 dependency and its native libraries have their own distribution requirements; applications should review those terms before shipping. Bundled fonts retain their own OFL licenses.
