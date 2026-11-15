import Capacitor
import UIKit
import UserNotifications
import WebKit

/// The app's side of `window.yuvaMobile` (the site only uses the bridge when it finds it, as with `window.yuvaDesktop`):
/// push registration (APNs), the app icon's badge, the voice room as a CallKit call, and notification taps.
/// Registered by YuvaBridgeViewController; the page-side object is `bridgeScript`.
@objc(YuvaMobilePlugin)
final class YuvaMobilePlugin: CAPInstancePlugin, CAPBridgedPlugin, NotificationHandlerProtocol {
    let identifier = "YuvaMobilePlugin"
    let jsName = "YuvaMobile"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "pushPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerPush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBadge", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notify", returnType: CAPPluginReturnPromise),
    ]

    /// The notification a cold start was opened from (SceneDelegate), opened once the web view exists.
    static var coldStartOpen: [AnyHashable: Any]?
    private static weak var shared: YuvaMobilePlugin?

    private var waitingForToken: [CAPPluginCall] = []
    private let voiceCall = YuvaCall()

    override func load() {
        YuvaMobilePlugin.shared = self
        bridge?.notificationRouter.pushNotificationHandler = self
        bridge?.notificationRouter.localNotificationHandler = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didRegister(_:)), name: .capacitorDidRegisterForRemoteNotifications, object: nil)
        center.addObserver(self, selector: #selector(didFailToRegister(_:)), name: .capacitorDidFailToRegisterForRemoteNotifications, object: nil)
        voiceCall.onAction = { [weak self] action in
            self?.notifyListeners("callAction", data: ["action": action], retainUntilConsumed: false)
        }
    }

    // MARK: Push

    @objc func pushPermission(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = "granted"
            case .denied: state = "denied"
            default: state = "default"
            }
            call.resolve(["state": state])
        }
    }

    /// Asks for permission when undecided, then resolves {token, environment} (hex APNs token), or {denied: true}.
    @objc func registerPush(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                call.resolve(["denied": true])
                return
            }
            DispatchQueue.main.async {
                self.waitingForToken.append(call)
                UIApplication.shared.registerForRemoteNotifications()
                // No answer from APNs (no network): don't keep the page waiting forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, let index = self.waitingForToken.firstIndex(where: { $0 === call }) else { return }
                    self.waitingForToken.remove(at: index)
                    call.reject("APNs did not answer")
                }
            }
        }
    }

    @objc private func didRegister(_ note: Notification) {
        guard let token = note.object as? Data else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let calls = waitingForToken
        waitingForToken.removeAll()
        for call in calls { call.resolve(["token": hex, "environment": environment]) }
    }

    @objc private func didFailToRegister(_ note: Notification) {
        let message = (note.object as? Error)?.localizedDescription ?? "registration failed"
        let calls = waitingForToken
        waitingForToken.removeAll()
        for call in calls { call.reject(message) }
    }

    @objc func setBadge(_ call: CAPPluginCall) {
        let count = max(0, call.getInt("count") ?? 0)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = count }
        }
        call.resolve()
    }

    /// A new message while the app is in the background but still running (in a voice room): the page's own
    /// notification, as the desktop shells show theirs. One per channel; a newer one replaces it.
    @objc func notify(_ call: CAPPluginCall) {
        guard let channelId = call.getInt("channelId") else {
            call.reject("channelId required")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String((call.getString("title") ?? "Yuva").prefix(200))
        content.body = String((call.getString("body") ?? "").prefix(500))
        content.sound = .default
        content.threadIdentifier = "ch-\(channelId)"
        content.userInfo = ["url": "/sohbet?open=\(channelId)", "channelId": channelId]
        let request = UNNotificationRequest(identifier: "ch-\(channelId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in call.resolve() }
    }

    // Shown by the page itself (toast, chime) while Yuva is in front.
    func willPresent(notification: UNNotification) -> UNNotificationPresentationOptions {
        return []
    }

    func didReceive(response: UNNotificationResponse) {
        open(response.notification.request.content.userInfo)
    }

    /// A tapped notification: `url` is a path on the site (as the service worker's), `channelId` / `notice` what the
    /// page does with it when it is already in the app (lodge-app.tsx); anywhere else the web view goes to `url`.
    static func openColdStart() {
        guard let payload = coldStartOpen, let plugin = shared else { return }
        coldStartOpen = nil
        plugin.open(payload)
    }

    private func open(_ userInfo: [AnyHashable: Any]) {
        DispatchQueue.main.async {
            guard let webView = self.bridge?.webView, let server = self.bridge?.config.serverURL else { return }
            let path = (userInfo["url"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/sohbet"
            var data: [String: Any] = ["url": path]
            if let channelId = userInfo["channelId"] as? Int { data["channelId"] = channelId }
            if let notice = userInfo["notice"] as? [String: Any] { data["notice"] = notice }
            let current = webView.url
            if current?.host == server.host, current?.path == "/sohbet", self.hasListeners("notificationOpen") {
                self.notifyListeners("notificationOpen", data: data, retainUntilConsumed: false)
            } else if let target = URL(string: path, relativeTo: server) {
                webView.load(URLRequest(url: target))
            }
        }
    }

    // MARK: Voice room

    /// {call: {room, lodge, muted} | null}: the room as a CallKit call (lock screen, Dynamic Island, the green pill),
    /// which also keeps the app's audio going in the background.
    @objc func setCall(_ call: CAPPluginCall) {
        let room = call.getObject("call")
        DispatchQueue.main.async {
            if let room, let name = room["room"] as? String {
                self.voiceCall.set(room: name, lodge: room["lodge"] as? String, muted: room["muted"] as? Bool ?? false)
            } else {
                self.voiceCall.end()
            }
            call.resolve()
        }
    }

    // MARK: Page side

    /// `window.yuvaMobile` on the site's own pages (WKUserScript at document start, after Capacitor's own bridge).
    static func bridgeScript(host: String?) -> WKUserScript {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let source = """
        (function () {
          if (location.hostname !== \(jsString(host ?? ""))) return;
          var plugin = function () { return window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.YuvaMobile; };
          var call = function (name, args) {
            var p = plugin();
            return p ? p[name](args || {}) : Promise.reject(new Error("YuvaMobile unavailable"));
          };
          var on = function (event, cb) {
            var p = plugin();
            if (!p) return function () {};
            var handle = p.addListener(event, cb);
            return function () { Promise.resolve(handle).then(function (h) { h && h.remove(); }); };
          };
          window.yuvaMobile = Object.freeze({
            platform: "ios",
            version: \(jsString(version)),
            build: \(jsString(build)),
            pushPermission: function () { return call("pushPermission").then(function (r) { return r.state; }); },
            registerPush: function () { return call("registerPush"); },
            setBadge: function (count) { call("setBadge", { count: count }).catch(function () {}); },
            setCall: function (room) { call("setCall", { call: room || null }).catch(function () {}); },
            notify: function (n) { call("notify", n).catch(function () {}); },
            onCallAction: function (cb) { return on("callAction", function (d) { cb(d.action); }); },
            onNotificationOpen: function (cb) { return on("notificationOpen", cb); }
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
