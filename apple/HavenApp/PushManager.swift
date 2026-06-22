import UIKit
import UserNotifications

/// Talks to the self-hosted Haven push relay (a blind Cloudflare Worker). Registers this
/// device's APNs token under our pseudonymous node id, and asks the relay to wake circle
/// members when we post/message — so notifications arrive even when the app is killed
/// (background fetch is unreliable; this is the real fix).
///
/// v1 sends a generic alert ("New message") — no content leaves the device. Showing the
/// actual text needs a Notification Service Extension (later), which is purely additive.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()
    static let relay = "https://haven-push.blaineams3.workers.dev"

    /// Ask for permission + register for remote notifications (call at launch).
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// APNs handed us a device token → register it with the relay under our node id.
    func registered(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let nodeId = myNodeId() else { return }
        post("/register", ["nodeId": nodeId, "token": hex, "sandbox": isSandbox])
    }

    /// Ask the relay to wake a (possibly offline) peer. Generic alert for now.
    func wake(_ nodeId: String) {
        guard !nodeId.isEmpty else { return }
        post("/notify", ["nodeId": nodeId, "ciphertext": "_"])
    }

    private var isSandbox: Bool {
        #if DEBUG
        return true   // Xcode/dev builds use the APNs sandbox
        #else
        return false  // TestFlight / App Store = production
        #endif
    }

    private func myNodeId() -> String? {
        guard let seed = AccountStore.storedSeed(), let acct = try? Account.fromSeed(seed: seed) else { return nil }
        return acct.nodeIdHex()
    }

    private func post(_ path: String, _ body: [String: Any]) {
        guard let url = URL(string: Self.relay + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}
