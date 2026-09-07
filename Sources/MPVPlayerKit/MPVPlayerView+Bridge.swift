import AVFoundation
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

extension MPVPlayerView {
    nonisolated func nextBufferingSessionGeneration() -> UInt64 {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        bufferingSessionGeneration &+= 1
        return bufferingSessionGeneration
    }

    nonisolated func currentBufferingSessionGeneration() -> UInt64 {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return bufferingSessionGeneration
    }

    nonisolated func nextPlaybackIntentGeneration() -> UInt64 {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        playbackIntentGeneration &+= 1
        return playbackIntentGeneration
    }

    nonisolated func currentPlaybackIntentGeneration() -> UInt64 {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return playbackIntentGeneration
    }

    nonisolated func isPlaybackIntentCurrent(_ generation: UInt64) -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return playbackIntentGeneration == generation
    }

    nonisolated func isStopped() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return stopped
    }

    nonisolated func isSetupFailed() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return setupFailed
    }

    nonisolated func setStopped(_ value: Bool) {
        playbackStateLock.lock()
        stopped = value
        playbackStateLock.unlock()
    }

    nonisolated func setSetupFailed(_ value: Bool) {
        playbackStateLock.lock()
        setupFailed = value
        playbackStateLock.unlock()
    }

    nonisolated func markStoppedIfNeeded() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        guard stopped == false else { return false }
        stopped = true
        return true
    }

    @discardableResult
    nonisolated func command(
        _ command: String,
        args: [String?] = [],
        handle: OpaquePointer? = nil,
        checkForErrors: Bool = true
    ) -> Int32 {
        guard let mpv = handle ?? self.mpv else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }

        mpvDebugLog("command \(command) argCount=\(args.count)")
        let returnValue = mpv_command(mpv, &cargs)
        if checkForErrors {
            checkError(returnValue, operation: "command \(command)")
        }
        mpvDebugLog("command \(command) status=\(returnValue)")
        return returnValue
    }

    @discardableResult
    nonisolated func commandAsync(
        _ command: String,
        args: [String?] = [],
        replyUserdata: UInt64,
        handle: OpaquePointer? = nil
    ) -> Int32 {
        guard let mpv = handle ?? self.mpv else {
            return MPV_ERROR_UNINITIALIZED.rawValue
        }
        var cargs = makeOwnedCArgs(command, args)
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }

        mpvDebugLog(
            "command async \(command) argCount=\(args.count) userdata=\(replyUserdata)"
        )
        let returnValue = mpv_command_async(mpv, replyUserdata, &cargs)
        mpvDebugLog(
            "command async \(command) status=\(returnValue) userdata=\(replyUserdata)"
        )
        return returnValue
    }

    nonisolated func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var stringArgs = args
        stringArgs.insert(command, at: 0)
        stringArgs.append(nil)
        return stringArgs
    }

    nonisolated func normalizedMPVSource(_ source: String) -> String {
        guard let url = URL(string: source) else {
            return source
        }
        return url.isFileURL ? url.path : url.absoluteString
    }

    nonisolated func makeOwnedCArgs(_ command: String, _ args: [String?]) -> [UnsafePointer<CChar>?] {
        var cargs: [UnsafePointer<CChar>?] = []
        for argument in makeCArgs(command, args) {
            guard let argument else {
                cargs.append(nil)
                continue
            }
            cargs.append(UnsafePointer<CChar>(strdup(argument)))
        }
        return cargs
    }

    nonisolated func makeMPVHTTPHeaderFields() -> (fields: [String], skippedAuthHeaders: Int) {
        var fields: [String] = []
        var skippedAuthHeaders = 0
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanValue = value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanKey.isEmpty == false, cleanValue.isEmpty == false else { continue }
            if isMPVAuthorizationHeader(cleanKey) {
                skippedAuthHeaders += 1
                continue
            }
            fields.append("\(cleanKey): \(cleanValue)")
        }
        return (fields, skippedAuthHeaders)
    }

    nonisolated func isMPVAuthorizationHeader(_ key: String) -> Bool {
        key.caseInsensitiveCompare("Authorization") == .orderedSame
            || key.caseInsensitiveCompare("X-Emby-Authorization") == .orderedSame
    }

    @discardableResult
    nonisolated func checkError(_ status: CInt, operation: String? = nil, notifyOnFailure: Bool = true) -> Bool {
        if status < 0 {
            let category = operation?.split(separator: " ").first.map(String.init) ?? "未知"
            recordDiagnosticEvent("MPV调用失败", fields: ["调用类别": category, "错误码": String(status)])
            if notifyOnFailure {
                notifyOnMain {
                    self.notifyState(.error)
                }
            }
            return false
        }
        return true
    }

    func performOnMPVQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    func redactedURLDescription(_ url: URL?) -> String {
        guard let url else { return "nil" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItemCount = components?.queryItems?.count ?? 0
        components?.query = nil
        return "\(components?.string ?? url.absoluteString) queryItems=\(queryItemCount)"
    }

    nonisolated var activeProfileDescription: String {
        guard setupProfiles.indices.contains(activeSetupProfileIndex) else {
            return "none"
        }
        return setupProfiles[activeSetupProfileIndex].name
    }

    func boolValue(_ value: Any?, default defaultValue: Bool = false) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return defaultValue
    }

    nonisolated func mpvDebugLog(_ message: @autoclosure () -> String) {
        // 历史自由文本包含地址、字体文件名等，不再输出或求值。
        // 使用 PowerDiagnostics 的白名单事件，避免隐私泄漏和高频字符串构造。
    }

    func notifyState(_ state: MPVPlayerState) {
        requestDiagnosticSnapshot("播放状态变化", fields: ["状态": String(describing: state)])
        mpvDebugLog(
            "notify state=\(state) current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
        )
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didChangeState,
                object: self,
                userInfo: [MPVPlayerKitNotificationKey.state: state.rawValue]
            )
        }
    }

    nonisolated func setDecoderMode(_ decoderMode: MPVPlayerDecoderMode) {
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didUpdateDecoderMode,
            object: self,
            userInfo: [MPVPlayerKitNotificationKey.decoderMode: decoderMode.rawValue]
        )
    }

    func notifyTime(currentTime: TimeInterval, duration: TimeInterval) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didUpdateTime,
                object: self,
                userInfo: [
                    MPVPlayerKitNotificationKey.currentTime: currentTime,
                    MPVPlayerKitNotificationKey.duration: duration,
                ]
            )
        }
    }

    func notifyBufferingProgress(_ bufferingProgress: Int) {
        mpvDebugLog(
            "notify buffering progress=\(bufferingProgress) current=\(currentTime) duration=\(duration)"
        )
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didUpdateBufferingProgress,
            object: self,
            userInfo: [MPVPlayerKitNotificationKey.bufferingProgress: bufferingProgress]
        )
    }

    func notifyBufferedProgress(_ bufferedProgress: Int?) {
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didUpdateBufferedProgress,
            object: self,
            userInfo: [
                MPVPlayerKitNotificationKey.bufferedProgress:
                    bufferedProgress.map(NSNumber.init(value:)) ?? NSNull()
            ]
        )
    }

    nonisolated func notifyOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
        } else {
            Task { @MainActor in
                body()
            }
        }
    }
}
