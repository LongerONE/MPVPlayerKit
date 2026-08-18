# MPVPlayerKit

An iOS 15+ Swift Package that wraps [MPVKit](https://github.com/mpvkit/MPVKit) with a small UIKit API.

## Features

- HTTP and local video playback
- Play, pause, stop, exact seek and playback-rate control
- Audio, video and subtitle track discovery and selection
- Framework-owned SRT/VTT parsing, timing, styling and default rendering
- Replaceable client subtitle renderer for custom application UI
- External ASS/SSA loading through MPV with original-style support
- Picture in Picture for custom and quick-player interfaces
- A reusable rendering view for custom player interfaces
- An optional ready-to-present `MPVQuickPlayerViewController`

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

Set `MPVPlayer.delegate` to receive state, time, buffering, decoder-mode and
Picture in Picture updates.

## Picture in Picture

Picture in Picture is available through `startPictureInPicture()`,
`stopPictureInPicture()`, and `togglePictureInPicture()`. The built-in quick
player starts Picture in Picture only after its button is tapped. Hosts that
explicitly opt into background-initiated Picture in Picture may set
`allowsAutomaticPictureInPictureFromInline`; this requires the Audio, AirPlay,
and Picture in Picture background mode.

The window is fed by raw MPV video screenshots, and is kept consistent with the
inline `MPVPlayerView`:

- The window is shaped like the video: frames carry the display aspect ratio MPV
  reports, so anamorphic video is not stretched and the shape of the drawable or
  of the fit/fill mode never leaks into the window.
- Captures follow the video frame rate up to 30 frames per second, and back off
  automatically when a capture costs more than its interval.
- Downscaling to the window size uses Accelerate resampling, and frames are
  forced opaque so nothing composites through the video.
- MPV subtitles are drawn into the captured frame with the player's own subtitle
  size, colors and bottom margin. Disable this with
  `drawsSubtitlesInPictureInPicture` when subtitles are composited outside of
  MPV. Image-based subtitle tracks (PGS, VobSub) have no text to draw, and
  original-style ASS tracks are drawn with the player style.
- The inline fit/fill mode does not change the window: it always shows the whole
  video frame at the aspect ratio of the video.

`pictureInPictureCaptureMode` selects how frames are captured:

- `.videoWithSubtitleOverlay` (default) reads back the raw video image, which
  never needs a video output render pass, and draws the subtitle line described
  above into it.
- `.window` reads back what MPV renders into its window and crops it to the
  video area, so MPV's own subtitles, fit/fill cropping and tone mapping come
  along, and the read back frame is the size of the drawable rather than of the
  video. It is experimental: the mode needs a video output render pass, which
  crashed on the builds that led to the default above. Verify on device.

The window controls play, pause, and skip backward and forward by the interval
the system asks for. Playback progress comes from the display layer timebase,
which carries the MPV position and the current playback rate; a stream with an
unknown duration is reported as live. The same position and rate are published
to the Now Playing controls on the lock screen and in Control Center.

Repeated skips accumulate: a seek publishes its target position immediately, so
the next skip starts from it instead of from the last position MPV reported.
Seeking while paused refreshes the window with the frame at the new position.

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

The quick interface provides play/pause, seeking, time display, a Picture in Picture button that enters and leaves the window, video/audio/subtitle track selection, external subtitle loading and cancellation, subtitle delay and style presets, playback speed, video quality, debanding, fit/fill display modes, decoder and buffering status, forced-landscape control, and a centered loading indicator. Its compact control bar uses system icons with accessibility labels. Forced landscape also works when the host app declares only portrait support: the quick player rotates its own content when system-level scene rotation is unavailable.

Landscape lock can also be changed while the player is visible:

```swift
playerViewController.setForceLandscape(true)
```

It also supports full-screen pan gestures: horizontal seeking, brightness on the left half and system volume on the right half. Each gesture can be disabled when the host app owns that interaction:

```swift
playerViewController.gestureOptions = [.seeking, .volume]
```

Settings can also be changed programmatically through `setPlaybackRate`, `setVideoQuality`, `setDebandEnabled`, `setSubtitleDelay`, and `setSubtitleStyle`. The underlying `player` remains public for direct access to every `MPVPlayer` operation.

It is optional; `MPVPlayer` does not depend on it at runtime.

## Demo

Open `Demo/MPVPlayerKitDemo.xcodeproj` and run the `MPVPlayerKitDemo` scheme. The Demo references this checkout as a local Swift Package and launches the quick player with a public HLS sample. Replace `sampleURL` in `Demo/MPVPlayerKitDemo/AppDelegate.swift` to test media with custom audio or subtitle tracks.

## Notes

- MPVKit is pinned to the `1.0.0` release so the native runtime and its transitive binary dependencies remain reproducible.
- The package is distributed as a dynamic library so MPVKit's native runtime stays isolated from an app's other media dependencies.
- The bundled Noto fonts are used for consistent multilingual subtitle rendering. Their original license files are included under `Resources`.

## License

This package's source code is available under the MIT License. MPVKit is an LGPL-3.0 dependency and its native libraries have their own distribution requirements; applications should review those terms before shipping. Bundled fonts retain their own OFL licenses.
