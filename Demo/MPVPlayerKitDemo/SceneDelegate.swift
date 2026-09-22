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

        let sampleURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8")!
        let playerViewController = MPVQuickPlayerViewController(url: sampleURL)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = playerViewController
        window.makeKeyAndVisible()
        self.window = window
    }
}
