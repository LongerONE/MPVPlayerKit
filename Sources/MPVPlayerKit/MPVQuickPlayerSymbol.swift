import UIKit

/// The shared SF Symbol vocabulary for the quick player's controls and gesture HUD.
enum MPVQuickPlayerSymbol: String, CaseIterable {
    case close = "xmark"
    case forceLandscape = "rectangle.landscape.rotate"
    case skipBackward15 = "gobackward.15"
    case skipForward15 = "goforward.15"
    case play = "play.fill"
    case pause = "pause.fill"
    case videoTrack = "film"
    case audioTrack = "waveform"
    case subtitles = "captions.bubble"
    case pictureInPictureEnter = "pip.enter"
    case pictureInPictureExit = "pip.exit"
    case settings = "gearshape"
    case seekBackward = "gobackward"
    case seekForward = "goforward"
    case brightness = "sun.max"
    case volumeMuted = "speaker.slash"
    case volume = "speaker.wave.2"

    static func image(
        _ symbol: Self,
        pointSize: CGFloat = 18,
        weight: UIImage.SymbolWeight = .semibold,
        scale: UIImage.SymbolScale = .medium
    ) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight,
            scale: scale
        )
        return UIImage(systemName: symbol.rawValue, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }
}
