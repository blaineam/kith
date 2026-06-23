#if os(macOS)
import SwiftUI
import AppKit

/// The menu-bar extra for the native Mac app — Haven's "invisible background relay" surface.
/// Closing the main window doesn't quit (see `applicationShouldTerminateAfterLastWindowClosed`),
/// so the in-process `RelayHost` keeps forwarding for your circles from here. Status + a relay
/// toggle + start-at-login + reopen/quit live in this menu.
struct MacMenuBarIcon: View {
    @ObservedObject private var relay = RelayHost.shared
    var body: some View {
        // Filled shield while actively serving; outline when off/idle.
        Image(systemName: relay.serving ? "shield.lefthalf.filled" : "shield")
    }
}

struct MacMenuBarContent: View {
    @ObservedObject private var relay = RelayHost.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if relay.serving {
                Text(relay.nodeId.isEmpty ? "Relay: serving" : "Relay: serving · \(relay.nodeId.prefix(8))…")
            } else if relay.enabled {
                Text("Relay: starting…")
            } else {
                Text("Relay: off")
            }

            Divider()

            Toggle("Run as a circle relay", isOn: Binding(
                get: { relay.enabled },
                set: { relay.setEnabled($0) }))
            Toggle("Start at login", isOn: Binding(
                get: { relay.startsAtLogin },
                set: { try? relay.setStartAtLogin($0) }))

            Divider()

            Button("Open Haven") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quit Haven") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
#endif
