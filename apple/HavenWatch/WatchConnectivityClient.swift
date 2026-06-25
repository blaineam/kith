import Foundation
import WatchConnectivity
import UserNotifications
import SwiftUI   // ImageRenderer for synthetic demo thumbnails

/// Watch-side WCSession client. The phone holds the iroh node + identity; this just asks the
/// phone for recent threads, displays them, and sends quick replies / reactions back. All
/// published state is mutated on the main actor so SwiftUI stays happy.
@MainActor
final class WatchConnectivityClient: NSObject, ObservableObject {
    static let shared = WatchConnectivityClient()

    @Published private(set) var threads: [WatchThread] = []
    @Published private(set) var openThread: WatchThreadDetail?
    @Published private(set) var reachable = false
    @Published private(set) var lastSyncedAt: UInt64 = 0
    /// True while we're waiting on a reply for the currently-open thread.
    @Published private(set) var loadingThread = false

    private var session: WCSession { WCSession.default }

    func start() {
        if seedDemoIfNeeded() { return }   // offline screenshot harness — no live session
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// HAVENWATCH_DEMO=1 — PII-free synthetic threads/messages so the UI is screenshottable
    /// without a paired iPhone (mirrors the phone app's DemoEnv harness). Returns true when
    /// seeded, so `start()` skips activating a real (empty) session.
    @discardableResult
    private func seedDemoIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.environment["HAVENWATCH_DEMO"] == "1" else { return false }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        threads = [
            WatchThread(id: "dm:ari", title: "Ari", subtitle: "On my way 🚲", timestamp: now - 90_000, isDM: true, unread: 1),
            WatchThread(id: "dm:noa", title: "Noa", subtitle: "❤️ that photo", timestamp: now - 1_800_000, isDM: true, unread: 0),
            WatchThread(id: "circle:trail", title: "Trail Crew", subtitle: "Sunset hike Saturday?", timestamp: now - 5_400_000, isDM: false, unread: 0),
        ]
        openThread = WatchThreadDetail(threadId: "dm:ari", title: "Ari", isDM: true, messages: [
            WatchMessage(id: "m1", author: "Ari", isMe: false, body: "Heading over now", timestamp: now - 240_000, hasMedia: false, reactions: "👍1"),
            WatchMessage(id: "m2", author: "You", isMe: true, body: "Cool, door's open", timestamp: now - 180_000, hasMedia: false, reactions: ""),
            WatchMessage(id: "m3", author: "Ari", isMe: false, body: "On my way 🚲", timestamp: now - 90_000, hasMedia: false, reactions: "❤️2"),
            WatchMessage(id: "m4", author: "Ari", isMe: false, body: "Made it to the top!", timestamp: now - 60_000, hasMedia: true,
                         reactions: "🔥3", media: Self.demoMedia()),
        ])
        reachable = true
        lastSyncedAt = now
        return true
    }

    /// Synthetic gradient "photos" standing in for real post media in the demo harness — two with
    /// different aspect ratios so the carousel + true-aspect rendering are exercised. (ImageRenderer is
    /// the watchOS-available rasterizer; UIGraphicsImageRenderer isn't.)
    @MainActor private static func demoMedia() -> [WatchMedia] {
        func gradient(_ a: Color, _ b: Color, _ w: Int, _ h: Int) -> WatchMedia? {
            let view = LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: CGFloat(w), height: CGFloat(h))
            let r = ImageRenderer(content: view); r.scale = 2
            return r.uiImage?.jpegData(compressionQuality: 0.6).map { WatchMedia(thumbnail: $0, w: w, h: h, isVideo: false) }
        }
        return [gradient(WTheme.pink, WTheme.violet, 160, 120),
                gradient(WTheme.violet, WTheme.amber, 120, 150)].compactMap { $0 }
    }

    // MARK: - Requests to the phone

    func refresh() {
        guard activated else { return }
        if session.isReachable {
            session.sendMessage(WatchCodec.encode(.requestSnapshot), replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: nil)
        }
        // Always fall back to whatever the phone last pushed as application context.
        ingest(session.receivedApplicationContext)
    }

    func openThread(_ threadId: String) {
        loadingThread = true
        // Show what we already have immediately if the same thread is cached.
        if openThread?.threadId != threadId { openThread = nil }
        guard activated, session.isReachable else { loadingThread = false; return }
        session.sendMessage(WatchCodec.encode(.requestThread, WatchThreadRequest(threadId: threadId)),
                            replyHandler: { [weak self] reply in
            Task { @MainActor in self?.ingest(reply) }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.loadingThread = false }
        })
    }

    func sendReply(threadId: String, body: String, targetId: String? = nil) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activated else { return }
        loadingThread = true
        let payload = WatchCodec.encode(.quickReply, WatchReply(threadId: threadId, body: trimmed, targetId: targetId))
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.loadingThread = false }
            })
        } else {
            // Queued delivery when the phone is briefly unreachable.
            session.transferUserInfo(payload)
            loadingThread = false
        }
    }

    func react(threadId: String, messageId: String, emoji: String) {
        guard activated else { return }
        let payload = WatchCodec.encode(.react, WatchReaction(threadId: threadId, messageId: messageId, emoji: emoji))
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
    }

    // MARK: - Inbound

    private var activated: Bool { session.activationState == .activated }

    private func ingest(_ message: [String: Any]) {
        switch WatchCodec.kind(of: message) {
        case .snapshot:
            if let snap = WatchCodec.decode(WatchSnapshot.self, from: message) {
                threads = snap.threads
                lastSyncedAt = snap.generatedAt
            }
        case .thread:
            if let detail = WatchCodec.decode(WatchThreadDetail.self, from: message) {
                openThread = detail
                loadingThread = false
            }
        case .notify:
            if let notice = WatchCodec.decode(WatchNotice.self, from: message) {
                postLocalNotification(notice)
            }
        default:
            break
        }
    }

    private func postLocalNotification(_ notice: WatchNotice) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "wmirror-\(notice.dedupeKey)", content: content, trigger: nil))
        refresh()   // freshen the thread list alongside the alert
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.reachable = session.isReachable
            self.refresh()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if session.isReachable { self.refresh() }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingest(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.ingest(message) }
    }
    #if os(iOS)
    // WCSessionDelegate requires these only on iOS — the watch app never compiles them on
    // watchOS, but the iOS SDK (used when this target is built alongside the phone) needs them
    // for protocol conformance.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}
