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
    @discardableResult
    func command(
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

    func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var stringArgs = args
        stringArgs.insert(command, at: 0)
        stringArgs.append(nil)
        return stringArgs
    }

    func makeMPVHTTPHeaderFields() -> (fields: [String], skippedAuthHeaders: Int) {
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

    func isMPVAuthorizationHeader(_ key: String) -> Bool {
        key.caseInsensitiveCompare("Authorization") == .orderedSame
            || key.caseInsensitiveCompare("X-Emby-Authorization") == .orderedSame
    }

    @discardableResult
    func checkError(_ status: CInt, operation: String? = nil, notifyOnFailure: Bool = true) -> Bool {
        if status < 0 {
            #if DEBUG
            let name = operation ?? "unknown"
            let message = String(cString: mpv_error_string(status))
            mpvDebugLog("api error operation=\(name) status=\(status) message=\(message)")
            #endif
            if notifyOnFailure {
                notifyState(.error)
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

    var activeProfileDescription: String {
        guard setupProfiles.indices.contains(activeSetupProfileIndex) else {
            return "none"
        }
        return setupProfiles[activeSetupProfileIndex].name
    }

    func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    func mpvDebugLog(_ message: String) {
        #if DEBUG
        print("MPVPlayerView[\(ObjectIdentifier(self))] \(message)")
        #endif
    }

    func notifyState(_ state: MPVPlayerState) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didChangeState,
                object: self,
                userInfo: [MPVPlayerKitNotificationKey.state: state.rawValue]
            )
        }
    }

    func setDecoderMode(_ decoderMode: MPVPlayerDecoderMode) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didUpdateDecoderMode,
                object: self,
                userInfo: [MPVPlayerKitNotificationKey.decoderMode: decoderMode.rawValue]
            )
        }
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
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didUpdateBufferingProgress,
            object: self,
            userInfo: [MPVPlayerKitNotificationKey.bufferingProgress: bufferingProgress]
        )
    }

    func notifyOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
