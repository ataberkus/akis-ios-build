import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Launched by tapping a notification: opened once the web view is up (YuvaBridgeViewController).
        YuvaMobilePlugin.coldStartOpen = connectionOptions.notificationResponse?.notification.request.content.userInfo

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = YuvaBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

/// Capacitor's view controller plus Yuva's native side: the YuvaMobile plugin and `window.yuvaMobile` on the site.
final class YuvaBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(YuvaMobilePlugin())
        webView?.configuration.userContentController.addUserScript(
            YuvaMobilePlugin.bridgeScript(host: bridge?.config.serverURL.host))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        YuvaMobilePlugin.openColdStart()
    }
}
