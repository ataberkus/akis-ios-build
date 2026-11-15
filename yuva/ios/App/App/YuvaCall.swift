import CallKit
import Foundation

/// The voice room as an outgoing CallKit call, while the page says you are in one (window.yuvaMobile.setCall): iOS
/// shows it on the lock screen, in the Dynamic Island and as the green pill, with mute and end, and treats the app as
/// on a call (its audio isn't cut when it goes to the background). Mute and end from there come back to the page as
/// `onAction("mute" | "unmute" | "leave")`; changes the page makes itself are not echoed back.
/// CallKit is not allowed on the App Store in China: leave that storefront out when publishing.
final class YuvaCall: NSObject, CXProviderDelegate {
    var onAction: ((String) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var current: UUID?
    private var name = ""
    /// The page's mute state, as last told or as last passed on to it.
    private var muted = false
    /// The end in flight was asked for by the page (it left the room): don't tell it to leave.
    private var endingFromPage = false

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// In a room (called again whenever the room, its lodge or the mute state changes; same values do nothing).
    func set(room: String, lodge: String?, muted: Bool) {
        let name = lodge.map { "\(room) · \($0)" } ?? room
        guard let id = current else {
            let id = UUID()
            current = id
            self.name = name
            self.muted = muted
            let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
            start.isVideo = false
            request(start) { [weak self] failed in
                if failed, self?.current == id { self?.current = nil }
            }
            return
        }
        if name != self.name {
            self.name = name
            provider.reportCall(with: id, updated: update())
        }
        if muted != self.muted {
            self.muted = muted
            request(CXSetMutedCallAction(call: id, muted: muted))
        }
    }

    /// Out of the room.
    func end() {
        guard let id = current else { return }
        endingFromPage = true
        request(CXEndCallAction(call: id)) { [weak self] failed in
            guard failed, let self else { return }
            self.endingFromPage = false
            if self.current == id { self.current = nil }
        }
    }

    private func update() -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    private func request(_ action: CXCallAction, done: ((Bool) -> Void)? = nil) {
        controller.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[yuva] CallKit \(type(of: action)): \(error.localizedDescription)") }
            DispatchQueue.main.async { done?(error != nil) }
        }
    }

    // MARK: CXProviderDelegate (main queue)

    func providerDidReset(_ provider: CXProvider) {
        current = nil
        endingFromPage = false
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        provider.reportCall(with: action.callUUID, updated: update())
        if muted { request(CXSetMutedCallAction(call: action.callUUID, muted: true)) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let fromPage = endingFromPage
        endingFromPage = false
        if current == action.callUUID { current = nil }
        action.fulfill()
        if !fromPage { onAction?("leave") }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        guard action.isMuted != muted else { return }
        muted = action.isMuted
        onAction?(action.isMuted ? "mute" : "unmute")
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }
}
