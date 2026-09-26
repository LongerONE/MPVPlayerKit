import UIKit

extension MPVPlayerView {
    func observeHardwareDecodeLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(captureBackgroundHardwareDecode),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(restoreForegroundHardwareDecode),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func captureBackgroundHardwareDecode() {
        let pictureInPicture = isPictureInPictureActive
        queue.async { [weak self] in
            guard let self, !self.isStopped(), self.mpv != nil else { return }
            self.backgroundHardwareDecode.capture(
                current: self.getString(MPVProperty.hwdecCurrent),
                forceSoftware: self.forceSoftwareDecode,
                pictureInPicture: pictureInPicture
            )
        }
    }

    @objc private func restoreForegroundHardwareDecode() {
        queue.async { [weak self] in
            self?.restoreBackgroundHardwareDecodeIfNeeded()
        }
    }

    nonisolated func restoreBackgroundHardwareDecodeIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let method = backgroundHardwareDecode.take(),
              !isStopped(), !forceSoftwareDecode, mpv != nil else { return }
        // 后台失效的 VT 会话在暂停时仍可能报告硬解。相同 hwdec 值不会触发
        // mpv 重建，先清除再恢复；mpv 保留 pause 并按当前视频时间精确刷新。
        let resetStatus = command("set", args: ["hwdec", "no"], checkForErrors: false)
        let restoreStatus = command("set", args: ["hwdec", method], checkForErrors: false)
        recordDiagnosticEvent("前台重建硬解", fields: [
            "硬解方式": method, "重置结果": String(resetStatus),
            "恢复结果": String(restoreStatus),
        ])
        refreshDecoderMode()
    }

    @objc public func configure(_ configuration: NSDictionary) {
        // 不在主线程读取 mpv 指针；stop 自身带 generation/stopped 守卫。
        stop()

        let urlString = configuration["url"] as? String
        url = urlString.flatMap(URL.init(string:))
        headers = configuration["headers"] as? [String: String] ?? [:]
        userAgent = configuration["userAgent"] as? String
        forceSoftwareDecode = boolValue(configuration["forceSoftwareDecode"])
        isDolbyVisionPlayback = boolValue(configuration["isDolbyVisionPlayback"])
        let qualityRawValue = (configuration["videoQuality"] as? NSNumber)?.intValue
        videoQualityPreset = qualityRawValue.flatMap(MPVVideoQualityPreset.init(rawValue:)) ?? .balanced
        debandEnabled = boolValue(configuration["debandEnabled"])
        cacheConfiguration = MPVCacheConfiguration(
            isEnabled: boolValue(configuration["cacheEnabled"], default: true),
            duration: (configuration["cacheDuration"] as? NSNumber)?.doubleValue ?? MPVCacheConfiguration.defaultDuration
        )
        configurePowerDiagnostics(configuration)
        setDecoderMode(.initializing)
        setStopped(false)
        setSetupFailed(false)
        setReadyToPlayReported(false)
        resetPictureInPictureVideoDisplaySize()
        setPlaybackRestarted(false)
        replaceSetupProfiles([], activeIndex: 0)
        pictureInPictureRendererRuntimeState.reset()
        stableMetalCanvas = nil
        videoDisplayAspectRatioLock.lock()
        videoDisplayAspectRatio = MPVDisplayGeometry.defaultVideoAspectRatio
        videoDisplayAspectRatioLock.unlock()
        pictureInPictureGeometryResynchronizationTask?.cancel()
        pictureInPictureGeometryResynchronizationTask = nil
        pictureInPictureGeometryResynchronizationGeneration &+= 1
        pendingPictureInPictureGeometryResynchronizationReason = nil
        currentTime = 0.0
        duration = 0.0
        bufferedProgress = nil
        isPlaying = false
        currentSubtitleFontCapability = .noSubtitle
        playbackSpeed = 1.0
        _ = nextPlaybackIntentGeneration()
        clearPendingPlaybackPositionUpdate()
        _ = nextBufferingSessionGeneration()
        queue.async { [weak self] in
            self?.resetBufferingStateOnMPVQueue(reason: "configure")
        }
        let colorHint = MPVColorMappingPolicy.contentHint(
            isDolbyVisionPlayback: isDolbyVisionPlayback
        )
        mpvDebugLog("configure url=\(redactedURLDescription(url)) headers=\(headers.count) hasUserAgent=\(userAgent?.isEmpty == false) forceSoftwareDecode=\(forceSoftwareDecode) contentColorHint=\(colorHint.rawValue)")
    }

}
