import MPVPlayerKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let sampleURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let playerViewController = MPVQuickPlayerViewController(url: sampleURL)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = playerViewController
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
