import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

/// Local notifications with **no server and no third party**. We can't (and won't)
/// run a push service that would learn who talks to whom. Instead: a periodic
/// background-refresh wake briefly brings up P2P networking, syncs with the circle,
/// and posts LOCAL notifications for anything new that arrived. When the app is alive
/// (foreground or briefly backgrounded), inbound events notify directly.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    static let refreshTaskId = "com.blaineam.kith.refresh"

    private var authorized = false
    private var notified = Set<String>()

    /// Ask once for permission to show local notifications.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Must run at launch (before the app finishes launching).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            // The launch handler runs on a PRIVATE (non-main) queue, so MainActor.assumeIsolated
            // would trap. Hop onto the main actor properly instead — this was the BG crash.
            Task { @MainActor in self.handleRefresh(refresh) }
        }
    }

    /// Ask iOS to wake us again later (it decides the real cadence).
    func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()   // chain the next wake
        let work = Task { @MainActor in
            FeedStore.shared.forceSync()
            // Give inbound a window to arrive (handleEvent fires notifications itself).
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Post a local notification (only when the app isn't in the foreground).
    func notify(title: String, body: String, dedupeKey: String) {
        guard authorized else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        guard !notified.contains(dedupeKey) else { return }
        notified.insert(dedupeKey)
        if notified.count > 3000 { notified.removeAll() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
