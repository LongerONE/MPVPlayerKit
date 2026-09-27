import UIKit

extension MPVQuickPlayerViewController {
    /// Creates a quick player from asynchronously resolved playlist items.
    public static func makePlaylistPlayer(
        items: [any MPVQuickPlayerPlaylistItem],
        initialIndex: Int = 0,
        configuration: MPVPlayerConfiguration? = nil,
        autoplay: Bool = true,
        forceLandscape: Bool = false
    ) async throws -> MPVQuickPlayerViewController {
        guard items.isEmpty == false else {
            throw MPVQuickPlayerPlaylistError.emptyPlaylist
        }
        guard items.indices.contains(initialIndex) else {
            throw MPVQuickPlayerPlaylistError.invalidInitialIndex
        }

        let resource = try await items[initialIndex].resolvePlaybackResource()
        var playerConfiguration = configuration ?? MPVPlayerConfiguration(url: resource.url)
        playerConfiguration.url = resource.url
        playerConfiguration.headers = resource.headers
        playerConfiguration.userAgent = resource.userAgent

        let viewController = MPVQuickPlayerViewController(
            configuration: playerConfiguration,
            autoplay: autoplay,
            forceLandscape: forceLandscape
        )
        viewController.playlistItems = items
        viewController.currentPlaylistIndex = initialIndex
        viewController.currentPlaylistTitle = resource.title
        viewController.playlistConfiguration = playerConfiguration
        return viewController
    }

    func configurePlaylistButton() {
        configureControlButton(
            playlistButton,
            symbol: .playlist,
            label: mpvLocalized("accessibility.playlist"),
            action: #selector(showPlaylist)
        )
        playlistButton.accessibilityIdentifier = "MPVQuickPlayer.playlistButton"
        updatePlaylistControls()
    }

    func updatePlaylistControls() {
        let count = playlistItems?.count ?? 0
        let hasPlaylist = count > 0
        let canNavigate = count > 1

        playlistButton.isHidden = hasPlaylist == false
        playlistButton.isEnabled = hasPlaylist && isPlaylistSwitching == false
        previousItemButton.isHidden = canNavigate == false
        previousItemButton.isEnabled = isPlaylistSwitching == false && currentPlaylistIndex > 0
        nextItemButton.isHidden = canNavigate == false
        nextItemButton.isEnabled = isPlaylistSwitching == false && currentPlaylistIndex < count - 1
    }

    @objc func showPlaylist() {
        guard let playlistItems, playlistItems.isEmpty == false else { return }
        let options = playlistItems.enumerated().map { index, item in
            MPVQuickPlayerActionSheetOption(
                title: index == currentPlaylistIndex
                    ? currentPlaylistTitle ?? item.title
                    : item.title,
                isSelected: index == currentPlaylistIndex
            ) { [weak self] in
                self?.switchPlaylistItem(to: index)
            }
        }
        presentActionSheet(
            title: mpvLocalized("playlist.title"),
            sourceView: playlistButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
    }

    @objc func playPreviousPlaylistItem() {
        switchPlaylistItem(to: currentPlaylistIndex - 1)
    }

    @objc func playNextPlaylistItem() {
        switchPlaylistItem(to: currentPlaylistIndex + 1)
    }

    func switchPlaylistItem(to index: Int) {
        guard let playlistItems,
              playlistItems.indices.contains(index),
              isPlaylistSwitching == false else { return }

        playlistSwitchTask?.cancel()
        playlistSwitchGeneration &+= 1
        let generation = playlistSwitchGeneration
        isPlaylistSwitching = true
        updatePlaylistControls()
        playlistSwitchTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.playlistSwitchGeneration == generation {
                    self.playlistSwitchTask = nil
                    self.isPlaylistSwitching = false
                    self.updatePlaylistControls()
                }
            }

            do {
                let resource = try await playlistItems[index].resolvePlaybackResource()
                try Task.checkCancellation()
                guard let self,
                      self.playlistSwitchGeneration == generation,
                      self.isBeingDismissed == false else { return }

                var configuration = self.playlistConfiguration
                    ?? MPVPlayerConfiguration(url: resource.url)
                configuration.url = resource.url
                configuration.headers = resource.headers
                configuration.userAgent = resource.userAgent
                configuration.videoQuality = self.videoQuality
                configuration.debandEnabled = self.debandEnabled
                configuration.cacheConfiguration = self.cacheConfiguration

                self.player.playbackView.configure(configuration.bridgeDictionary)
                self.playlistConfiguration = configuration
                self.currentPlaylistIndex = index
                self.currentPlaylistTitle = resource.title
                self.updatePlaylistControls()
                self.player.play()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.playlistSwitchGeneration == generation else { return }
                self.presentMessage(
                    title: mpvLocalized("playlist.error.title"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
