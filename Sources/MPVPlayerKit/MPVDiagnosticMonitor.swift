import Darwin
import UIKit

@MainActor
final class MPVDiagnosticMonitor {
    let channel: MPVDiagnosticChannel
    var periodicSnapshotPending = false
    private weak var playerView: MPVPlayerView?
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var monitoringBattery = false
    private static var batteryMonitorCount = 0
    private static var batteryMonitoringWasEnabled = false

    init(playerView: MPVPlayerView, channel: MPVDiagnosticChannel) {
        self.playerView = playerView
        self.channel = channel
    }

    func start(source: MPVDiagnosticSource, host: MPVDiagnosticHost) {
        if Self.batteryMonitorCount == 0 {
            Self.batteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        Self.batteryMonitorCount += 1
        monitoringBattery = true
        var machine = utsname()
        uname(&machine)
        let machineName = withUnsafeBytes(of: &machine.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        playerView?.requestDiagnosticSnapshot("会话开始", fields: [
            "设备型号": machineName,
            "系统版本": UIDevice.current.systemVersion,
            "构建类型": build,
            "宿主": host.rawValue,
            "来源": source.rawValue,
            "MPVKit版本": "1.0.0",
            "App版本": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不可用",
            "App构建号": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不可用",
            "逻辑核心数": String(ProcessInfo.processInfo.processorCount),
            "采样间隔秒": "5",
            "CPU口径": "App进程，100%为一个逻辑核心，可超过100%",
            "GPU功耗瓦数": "不可用，需Instruments采样",
            "芯片温度摄氏度": "不可用，系统仅公开热状态等级",
            "电池状态口径": "诊断期间启用电池监测，最后一个会话停止时恢复先前设置",
        ])
        let notifications: [(Notification.Name, String)] = [
            (ProcessInfo.thermalStateDidChangeNotification, "系统热状态变化"),
            (.NSProcessInfoPowerStateDidChange, "低电量模式变化"),
            (UIDevice.batteryStateDidChangeNotification, "充电状态变化"),
            (UIApplication.didEnterBackgroundNotification, "进入后台"),
            (UIApplication.willEnterForegroundNotification, "返回前台"),
            (MPVPlayerKitNotification.didChangePictureInPicture, "画中画状态变化"),
        ]
        for (name, event) in notifications {
            let object: AnyObject? = name == MPVPlayerKitNotification.didChangePictureInPicture ? playerView : nil
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.playerView?.requestDiagnosticSnapshot(event)
                }
            })
        }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, !self.stopped else { return }
                self.playerView?.requestDiagnosticSnapshot("周期快照")
            }
        }
    }

    func systemFields() -> [String: String] {
        guard let playerView else { return [:] }
        let screen = playerView.window?.windowScene?.screen
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "轻度"
        case .serious: thermal = "严重"
        case .critical: thermal = "临界"
        @unknown default: thermal = "未知"
        }
        let battery: String
        if UIDevice.current.isBatteryMonitoringEnabled {
            switch UIDevice.current.batteryState {
            case .unplugged: battery = "未充电"
            case .charging: battery = "充电中"
            case .full: battery = "已充满"
            default: battery = "不可用"
            }
        } else {
            battery = "不可用"
        }
        var values: [String: String] = [
            "热状态": thermal,
            "低电量模式": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "电池状态": battery,
            "屏幕亮度": screen.map { String(format: "%.3f", $0.brightness) } ?? "不可用",
            "屏幕原生尺寸": screen.map { NSCoder.string(for: $0.nativeBounds.size) } ?? "不可用",
            "屏幕原生缩放": screen.map { String(describing: $0.nativeScale) } ?? "不可用",
            "屏幕最大刷新率": screen.map { String($0.maximumFramesPerSecond) } ?? "不可用",
            "EDR启用": String(playerView.usesExtendedDynamicRangeOutput),
            "当前EDR余量": "不可用",
            "潜在EDR余量": "不可用",
            "渲染画布像素尺寸": NSCoder.string(for: playerView.metalLayer.drawableSize),
            "显示视图尺寸": NSCoder.string(for: playerView.bounds.size),
            "Metal像素格式": String(playerView.metalLayer.pixelFormat.rawValue),
            "画中画": String(playerView.isPictureInPictureActive),
            "App状态": String(describing: UIApplication.shared.applicationState),
        ]
        if #available(iOS 16.0, *), let screen {
            values["当前EDR余量"] = String(describing: screen.currentEDRHeadroom)
            values["潜在EDR余量"] = String(describing: screen.potentialEDRHeadroom)
        }
        return values
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if monitoringBattery {
            Self.batteryMonitorCount -= 1
            if Self.batteryMonitorCount == 0 {
                UIDevice.current.isBatteryMonitoringEnabled = Self.batteryMonitoringWasEnabled
            }
        }
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    isolated deinit { stop() }
}
