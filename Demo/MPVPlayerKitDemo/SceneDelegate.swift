import MPVPlayerKit
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        if ProcessInfo.processInfo.arguments.contains("--dual-subtitle-regression") {
            let controller = UIViewController()
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.window = window
            Task { await SubtitleRegression.run(in: controller) }
            return
        }
        let diagnosticMode = ProcessInfo.processInfo.arguments.contains("--dual-subtitle-demo")
        let sampleURL = diagnosticMode
            ? Bundle.main.url(forResource: "dual-subtitles", withExtension: "mp4", subdirectory: "SubtitleFixtures")!
            : URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8")!
        let playerViewController = MPVQuickPlayerViewController(url: sampleURL)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = diagnosticMode || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? playerViewController : UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        if diagnosticMode {
            Task { @MainActor [weak playerViewController] in
                guard let controller = playerViewController else { return }
                let deadline = Date().addingTimeInterval(8)
                while controller.player.duration == 0 && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard controller.player.duration > 0 else { return }
                var completedLoads = 0
                for (name, slot) in [("primary.srt", MPVSubtitleSlot.primary),
                                     ("secondary.vtt", MPVSubtitleSlot.secondary)] {
                    guard let url = Bundle.main.url(forResource: name, withExtension: nil,
                                                    subdirectory: "SubtitleFixtures") else { continue }
                    controller.player.loadExternalSubtitle(from: url, in: slot) { success in
                        if success {
                            controller.player.seek(to: 2)
                            controller.player.pause()
                            completedLoads += 1
                            if completedLoads == 2 {
                                Task { @MainActor in
                                    let deadline = Date().addingTimeInterval(5)
                                    while Date() < deadline {
                                        let primary = controller.player.currentSubtitleText(in: .primary)
                                        let secondary = controller.player.currentSubtitleText(in: .secondary)
                                        if primary?.contains("PRIMARY_ALPHA") == true,
                                           secondary?.contains("SECONDARY_ONE") == true {
                                            let ready = UILabel()
                                            ready.text = "双字幕诊断已就绪"
                                            ready.textColor = .white
                                            ready.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                                            ready.font = .systemFont(ofSize: 12)
                                            ready.frame = CGRect(x: 20, y: 80, width: 160, height: 24)
                                            controller.view.addSubview(ready)
                                            return
                                        }
                                        controller.player.seek(to: 2)
                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
