import Foundation
import UIKit

public enum MPVPlaybackState: Int, Sendable {
    case buffering
    case readyToPlay
    case bufferFinished
    case paused
    case playedToTheEnd
    case error
}

public enum MPVDecoderMode: Int, Sendable {
    case initializing
    case hardware
    case software
}

public enum MPVVideoQuality: Int, Sendable {
    case powerSaving
    case balanced
    case highQuality
}

/// Runtime cache settings shared by the MPV player and quick-player UI.
public struct MPVCacheConfiguration: Equatable, Sendable {
    /// Supported cache durations in seconds.
    public static let availableDurations: [TimeInterval] = [10, 30, 60, 120]
    /// The default cache duration in seconds.
    public static let defaultDuration: TimeInterval = 30

    public var isEnabled: Bool
    public var duration: TimeInterval {
        didSet {
            duration = Self.nearestDuration(duration)
        }
    }
    public init(
        isEnabled: Bool = true,
        duration: TimeInterval = Self.defaultDuration
    ) {
        self.isEnabled = isEnabled
        self.duration = Self.nearestDuration(duration)
    }

    public static let `default` = MPVCacheConfiguration()

    public static func nearestDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return defaultDuration }
        return availableDurations.min {
            abs($0 - duration) < abs($1 - duration)
        } ?? defaultDuration
    }

    var bridgeDictionary: NSDictionary {
        [
            "cacheEnabled": NSNumber(value: isEnabled),
            "cacheDuration": NSNumber(value: duration),
        ] as NSDictionary
    }
}

public struct MPVSubtitleStyle: Equatable, Sendable {
    public var fontSize: Double
    public var fontName: String?
    public var bold: Bool
    public var textColor: String
    public var outlineSize: Double
    public var outlineColor: String
    public var shadowOffset: Double
    public var backgroundColor: String
    public var bottomOffset: Double
    public var shadowColor: String

    public init(
        fontSize: Double = 38,
        fontName: String? = nil,
        bold: Bool = false,
        textColor: String = "#FFFFFFFF",
        outlineSize: Double = 0,
        outlineColor: String = "#FF000000",
        shadowOffset: Double = 0,
        backgroundColor: String = "#00000000",
        bottomOffset: Double = 34,
        shadowColor: String = "#FF000000"
    ) {
        self.fontSize = fontSize.isFinite ? min(max(fontSize, 8), 120) : 38
        self.fontName = fontName
        self.bold = bold
        self.textColor = textColor
        self.outlineSize = outlineSize.isFinite ? min(max(outlineSize, 0), 10) : 0
        self.outlineColor = outlineColor
        self.shadowOffset = shadowOffset.isFinite ? min(max(shadowOffset, 0), 10) : 0
        self.backgroundColor = backgroundColor
        self.bottomOffset = bottomOffset.isFinite ? min(max(bottomOffset, 0), 300) : 34
        self.shadowColor = shadowColor
    }

    public static let defaultStyle = MPVSubtitleStyle()
    public static let large = MPVSubtitleStyle(fontSize: 52, outlineSize: 1.5)
    public static let highContrast = MPVSubtitleStyle(
        fontSize: 42,
        bold: true,
        outlineSize: 2,
        shadowOffset: 1,
        backgroundColor: "#80000000",
        shadowColor: "#FF000000"
    )

    var bridgeDictionary: NSDictionary {
        var values: [String: Any] = [
            "fontSize": NSNumber(value: fontSize),
            "bold": NSNumber(value: bold),
            "textColor": textColor,
            "outlineSize": NSNumber(value: outlineSize),
            "outlineColor": outlineColor,
            "shadowOffset": NSNumber(value: shadowOffset),
            "backgroundColor": backgroundColor,
            "bottomOffset": NSNumber(value: bottomOffset),
            "shadowColor": shadowColor,
        ]
        if let fontName {
            values["fontName"] = fontName
        }
        return values as NSDictionary
    }
}

public enum MPVMediaTrackType: String, CaseIterable, Sendable {
    case video
    case audio
    case subtitle = "sub"
}

public struct MPVPlayerConfiguration: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var userAgent: String?
    public var forceSoftwareDecode: Bool
    public var isDolbyVisionPlayback: Bool
    public var videoQuality: MPVVideoQuality
    public var debandEnabled: Bool
    public var cacheConfiguration: MPVCacheConfiguration

    public init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = nil,
        forceSoftwareDecode: Bool = false,
        isDolbyVisionPlayback: Bool = false,
        videoQuality: MPVVideoQuality = .balanced,
        debandEnabled: Bool = false,
        cacheConfiguration: MPVCacheConfiguration = .default
    ) {
        self.url = url
        self.headers = headers
        self.userAgent = userAgent
        self.forceSoftwareDecode = forceSoftwareDecode
        self.isDolbyVisionPlayback = isDolbyVisionPlayback
        self.videoQuality = videoQuality
        self.debandEnabled = debandEnabled
        self.cacheConfiguration = cacheConfiguration
    }

    var bridgeDictionary: NSDictionary {
        var values: [String: Any] = [
            "url": url.absoluteString,
            "headers": headers,
            "forceSoftwareDecode": NSNumber(value: forceSoftwareDecode),
            "isDolbyVisionPlayback": NSNumber(value: isDolbyVisionPlayback),
            "videoQuality": NSNumber(value: videoQuality.rawValue),
            "debandEnabled": NSNumber(value: debandEnabled),
        ]
        values["cacheEnabled"] = NSNumber(value: cacheConfiguration.isEnabled)
        values["cacheDuration"] = NSNumber(value: cacheConfiguration.duration)
        if let userAgent, userAgent.isEmpty == false {
            values["userAgent"] = userAgent
        }
        return values as NSDictionary
    }
}

public struct MPVMediaTrack: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let type: MPVMediaTrackType
    public let name: String
    public let languageCode: String?
    public let codec: String
    public let bitRate: Int64
    public let isSelected: Bool
    public let isImageSubtitle: Bool

    public var subtitleFontCapability: MPVSubtitleFontCapability {
        guard type == .subtitle else { return .noSubtitle }
        return isImageSubtitle ? .unsupported : .supported
    }

    init?(dictionary: NSDictionary) {
        guard let id = (dictionary["trackID"] as? NSNumber)?.int32Value,
              let rawType = dictionary["mpvType"] as? String,
              let type = MPVMediaTrackType(rawValue: rawType) else {
            return nil
        }
        self.id = id
        self.type = type
        self.name = dictionary["name"] as? String ?? "Track \(id)"
        self.languageCode = dictionary["languageCode"] as? String
        self.codec = dictionary["codec"] as? String ?? ""
        self.bitRate = (dictionary["bitRate"] as? NSNumber)?.int64Value ?? 0
        self.isSelected = (dictionary["isEnabled"] as? NSNumber)?.boolValue ?? false
        self.isImageSubtitle = (dictionary["isImageSubtitle"] as? NSNumber)?.boolValue ?? false
    }
}
