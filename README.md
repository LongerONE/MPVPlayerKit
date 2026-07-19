# MPVPlayerKit

An iOS 15+ Swift Package that wraps [MPVKit](https://github.com/mpvkit/MPVKit) with a small UIKit API.

## Features

- HTTP and local video playback
- Play, pause, stop, exact seek and playback-rate control
- Audio, video and subtitle track discovery and selection
- External subtitle loading, visibility and delay control
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

let audioTracks = player.tracks(ofType: .audio)
if let track = audioTracks.first {
    player.select(track: track)
}

let subtitleTracks = player.tracks(ofType: .subtitle)
if let subtitle = subtitleTracks.first {
    player.select(track: subtitle)
}
```

Set `MPVPlayer.delegate` to receive state, time, buffering and decoder-mode updates.

## Frame interpolation

Choose one of the built-in interpolation profiles when creating the player:

```swift
let configuration = MPVPlayerConfiguration(
    url: videoURL,
    interpolationOptions: .smooth
)
```

The profiles use mpv's temporal scaling filters: `.standard` uses `oversample`, `.smooth` uses `linear`, and `.highQuality` uses `mitchell` with antiring. Advanced callers can construct `MPVInterpolationOptions` to select a different `MPVTemporalScaler` and tune `threshold`, `blur`, `clamp`, `radius`, or `antiring`. This is mpv frame mixing/resampling rather than motion-compensated AI frame generation.

Apply a new profile during playback with `player.updateVideoRenderOptions(debandEnabled:interpolationOptions:)`.

The legacy `smoothPlaybackEnabled` configuration remains supported and maps to the standard profile.

## Quick player interface

For apps that do not need custom controls:

```swift
let playerViewController = MPVQuickPlayerViewController(
    url: videoURL,
    forceLandscape: true
)
present(playerViewController, animated: true)
```

The quick interface provides play/pause, seeking, time display, video/audio/subtitle track selection, external subtitle loading and cancellation, subtitle delay and style presets, playback speed, video quality, debanding, frame interpolation, fit/fill display modes, decoder and buffering status, forced-landscape control, and a centered loading indicator. Its compact control bar uses SF Symbols with accessibility labels. The host app must include landscape-right in its supported interface orientations.

Landscape lock can also be changed while the player is visible:

```swift
playerViewController.setForceLandscape(true)
```

It also supports full-screen pan gestures: horizontal seeking, brightness on the left half and system volume on the right half. Each gesture can be disabled when the host app owns that interaction:

```swift
playerViewController.gestureOptions = [.seeking, .volume]
```

Settings can also be changed programmatically through `setPlaybackRate`, `setVideoQuality`, `setDebandEnabled`, `setInterpolationOptions`, `setSubtitleDelay`, and `setSubtitleStyle`. The underlying `player` remains public for direct access to every `MPVPlayer` operation.

It is optional; `MPVPlayer` does not depend on it at runtime.

## Demo

Open `Demo/MPVPlayerKitDemo.xcodeproj` and run the `MPVPlayerKitDemo` scheme. The Demo references this checkout as a local Swift Package and launches the quick player with a public HLS sample. Replace `sampleURL` in `Demo/MPVPlayerKitDemo/AppDelegate.swift` to test media with custom audio or subtitle tracks.

## Notes

- MPVKit uses a semantic-versioned dependency starting at `0.41.0`, so tagged releases of this package remain reproducible and compatible with SwiftPM's version rules.
- The package is distributed as a dynamic library so MPVKit's native runtime stays isolated from an app's other media dependencies.
- The bundled Noto fonts are used for consistent multilingual subtitle rendering. Their original license files are included under `Resources`.

## License

This package's source code is available under the MIT License. MPVKit is an LGPL-3.0 dependency and its native libraries have their own distribution requirements; applications should review those terms before shipping. Bundled fonts retain their own OFL licenses.
