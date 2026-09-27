import Foundation

/// A playlist item that can resolve its playback URL when it is selected.
@MainActor
public protocol MPVQuickPlayerPlaylistItem {
    var title: String { get }
    func resolvePlaybackResource() async throws -> MPVQuickPlayerPlaybackResource
}

/// The resolved media and request options needed to start playback.
public struct MPVQuickPlayerPlaybackResource: Sendable {
    public let url: URL
    public let title: String
    public let headers: [String: String]
    public let userAgent: String?

    public init(
        url: URL,
        title: String,
        headers: [String: String] = [:],
        userAgent: String? = nil
    ) {
        self.url = url
        self.title = title
        self.headers = headers
        self.userAgent = userAgent
    }
}

public enum MPVQuickPlayerPlaylistError: LocalizedError {
    case emptyPlaylist
    case invalidInitialIndex

    public var errorDescription: String? {
        switch self {
        case .emptyPlaylist:
            MPVLocalization.string("playlist.error.empty")
        case .invalidInitialIndex:
            MPVLocalization.string("playlist.error.invalid_index")
        }
    }
}
