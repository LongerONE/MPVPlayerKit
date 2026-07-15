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

## Quick player interface

For apps that do not need custom controls:

```swift
let playerViewController = MPVQuickPlayerViewController(url: videoURL)
present(playerViewController, animated: true)
```

The quick interface includes play/pause, seeking, time display, audio selection and subtitle selection. It also supports full-screen pan gestures: horizontal seeking, brightness on the left half and system volume on the right half. Each gesture can be disabled when the host app owns that interaction:

```swift
playerViewController.gestureOptions = [.seeking, .volume]
```

It is optional; `MPVPlayer` does not depend on it at runtime.

## Demo

Open `Demo/MPVPlayerKitDemo.xcodeproj` and run the `MPVPlayerKitDemo` scheme. The Demo references this checkout as a local Swift Package and launches the quick player with a public HLS sample. Replace `sampleURL` in `Demo/MPVPlayerKitDemo/AppDelegate.swift` to test media with custom audio or subtitle tracks.

## Notes

- MPVKit uses a semantic-versioned dependency starting at `0.41.0`, so tagged releases of this package remain reproducible and compatible with SwiftPM's version rules.
- The package is distributed as a dynamic library so MPVKit's native runtime stays isolated from an app's other media dependencies.
- The bundled Noto fonts are used for consistent multilingual subtitle rendering. Their original license files are included under `Resources`.

## License

This package's source code is available under the MIT License. MPVKit is an LGPL-3.0 dependency and its native libraries have their own distribution requirements; applications should review those terms before shipping. Bundled fonts retain their own OFL licenses.
