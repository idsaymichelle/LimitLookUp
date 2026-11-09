import Foundation
import WatchConnectivity

/// Sends the latest readings to the paired Apple Watch. Only percentages and dates leave the phone, never logins.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ usage: [ServiceUsage]) {
        let s = WCSession.default
        guard WCSession.isSupported(), s.activationState == .activated, s.isPaired,
              let data = try? JSONEncoder().encode(usage) else { return }
        // Context is delivered whenever the watch app next runs; a message arrives at once if it is open now.
        if s.isWatchAppInstalled { try? s.updateApplicationContext(["usage": data]) }
        if s.isReachable { s.sendMessage(["usage": data], replyHandler: nil) }
    }

    // The watch app may be installed or opened after the phone already sent; send again then.
    func sessionWatchStateDidChange(_ s: WCSession) { send(Store.load()) }
    func sessionReachabilityDidChange(_ s: WCSession) { send(Store.load()) }

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        send(Store.load())
    }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { s.activate() } // after switching watches
}
