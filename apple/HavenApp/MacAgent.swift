#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if targetEnvironment(macCatalyst)

/// Runs the Mac (Catalyst) app as an INVISIBLE background agent while it's serving as a circle
/// relay. Closing the window keeps the process — and the relay — alive, but drops the dock icon and
/// menu bar (AppKit's "accessory" activation policy). Launching Haven again brings the window back.
///
/// Catalyst exposes no public API for the activation policy, so we bridge to AppKit's
/// `NSApplication` through the Objective-C runtime. (A relay host shouldn't have to leave a window
/// open just to keep their circle's mailbox available.)
enum MacAgent {
    private static var firstSceneHandled = false

    /// NSApplicationActivationPolicy: 0 = regular (dock icon + menu bar), 1 = accessory (no dock
    /// icon / menu bar, but still running and interactive when a window opens).
    private static func setPolicy(_ policy: Int) {
        guard let appClass = NSClassFromString("NSApplication") else { return }
        guard let shared = (appClass as AnyObject)
                .perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("setActivationPolicy:")
        guard shared.responds(to: sel), let imp = shared.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(shared, sel, policy)
    }

    /// Hide the dock icon + menu bar; the process keeps running (the relay keeps serving). A dock
    /// shortcut the user PINNED stays put — accessory only hides the running-app icon, not a pin.
    static func goInvisible() { setPolicy(1) }
    /// Restore a normal, visible app (dock icon + menu bar).
    static func goVisible() { setPolicy(0) }

    /// Wire window (scene) connect/disconnect so closing the last window goes invisible when we're a
    /// relay, and (re)launching brings the app back. Call once at launch.
    static func installSceneObservers() {
        let c = NotificationCenter.default
        c.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            // The FIRST window of the process, when we're a relay set to start at login, is (almost
            // always) the silent login launch — hide it immediately so login is invisible, and the
            // user launches Haven a second time to actually open it. Every later window shows
            // normally, so that second launch (and any close→reopen) gives a real window.
            if !firstSceneHandled {
                firstSceneHandled = true
                if RelayHost.shared.enabled, RelayHost.shared.startsAtLogin,
                   let scene = note.object as? UIWindowScene {
                    goInvisible()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
                    }
                    return
                }
            }
            goVisible()
        }
        c.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
            // Window closed: if none remain and we're a relay, keep running invisibly (no dock icon).
            DispatchQueue.main.async {
                let live = UIApplication.shared.connectedScenes.contains { $0.activationState != .unattached }
                if !live, RelayHost.shared.enabled { goInvisible() }
            }
        }
    }
}
#endif
