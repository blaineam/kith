import SwiftUI

/// Mac Catalyst sheets have no built-in way to dismiss (no swipe-down, no nav chrome), so a sheet
/// can trap the user. This overlays a close button in the top-trailing corner — but ONLY on
/// Catalyst, so iOS keeps its native swipe-to-dismiss and we don't double up on a Done button.
private struct MacSheetClose: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // A "Done" button in the top-TRAILING corner. Leading overlapped a pushed view's back
        // chevron; trailing is clear now that the one sheet with its own trailing action
        // (EditProfileSheet) no longer uses this modifier. Inset down a hair so it sits below the
        // window's traffic-light row.
        content.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HavenTheme.pink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc closes it too
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Add a Catalyst-only top-corner close button to a sheet's content.
    func macSheetClose() -> some View { modifier(MacSheetClose()) }
}
