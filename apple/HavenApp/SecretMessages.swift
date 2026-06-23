import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// "Secret" DM messages: concealed until tapped, screenshot-protected, and auto-conceal
/// after a few seconds. The secret flag rides in the message body behind a control char,
/// so it travels through the same sealed engine as any message.
enum SecretMessages {
    private static let marker = "\u{2}"
    static func encode(_ text: String) -> String { marker + text }
    static func isSecret(_ body: String) -> Bool { body.hasPrefix(marker) }
    static func text(_ body: String) -> String { isSecret(body) ? String(body.dropFirst()) : body }
}

/// A concealed message bubble: tap to reveal (screenshot-blocked), auto-conceals after 5s
/// and re-conceals immediately if a screenshot is taken.
struct SecretBubble: View {
    let text: String
    let isMe: Bool
    @State private var revealed = false
    @State private var concealTask: Task<Void, Never>?

    var body: some View {
        Group {
            if revealed {
                // The message renders normally on screen but lives inside a secure-text-entry
                // layer, so the system EXCLUDES it from screenshots AND screen recordings (they
                // capture black). Screenshot *detection* below stays as a belt-and-suspenders.
                Text(text)
                    .font(.body)
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .screenshotProtected()
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption)
                    Text("Tap to reveal").italic()
                }
                .font(.subheadline)
                .foregroundStyle(isMe ? Color.white.opacity(0.92) : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
        .background(isMe ? AnyShapeStyle(HavenTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !revealed { Image(systemName: "eye.slash.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).padding(5) }
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        #if canImport(UIKit)
        // iOS notifies when a screenshot is taken; re-conceal. No macOS equivalent.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { revealed = false }
        }
        #endif
        .onDisappear { concealTask?.cancel() }
    }

    private func reveal() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { revealed.toggle() }
        concealTask?.cancel()
        if revealed {
            concealTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run { withAnimation(.easeOut(duration: 0.3)) { revealed = false } }
                }
            }
        }
    }
}

#if os(macOS)
/// Native macOS has no per-view secure-entry canvas like iOS. Instead, while the protected
/// content is on screen (i.e. a secret is revealed) we mark the hosting window as excluded from
/// screen capture/screenshots via `NSWindow.sharingType = .none`, restoring the prior value when
/// the content goes away. This blanks the *window* in any capture for the brief, user-initiated
/// reveal — coarser than iOS's per-view exclusion, but it keeps the secret out of screenshots
/// and screen recordings.
struct ScreenshotProtected<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.background(WindowCaptureExcluder()) }
}

private struct WindowCaptureExcluder: NSViewRepresentable {
    func makeNSView(context: Context) -> ExcluderView { ExcluderView() }
    func updateNSView(_ nsView: ExcluderView, context: Context) {}
    static func dismantleNSView(_ nsView: ExcluderView, coordinator: ()) { nsView.restore() }

    final class ExcluderView: NSView {
        private weak var trackedWindow: NSWindow?
        private var priorSharing: NSWindow.SharingType = .readOnly
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            trackedWindow = w
            priorSharing = w.sharingType
            w.sharingType = .none   // exclude from screen capture / screenshots
        }
        func restore() { trackedWindow?.sharingType = priorSharing; trackedWindow = nil }
    }
}
#else
/// Hosts a SwiftUI view inside a secure-text-entry layer, which iOS excludes from
/// screenshots and screen recordings.
struct ScreenshotProtected<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.host = host

        // Keep the secure field IN the view hierarchy (its secure-entry mode is what makes the
        // system exclude its canvas from captures); host the content inside that canvas. Detaching
        // the canvas from the field — the old approach — dropped the protection and blanked it.
        let wrapper = UIView()
        wrapper.backgroundColor = .clear
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.backgroundColor = .clear
        field.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            field.topAnchor.constraint(equalTo: wrapper.topAnchor),
            field.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        let canvas = field.subviews.first ?? wrapper   // the protected canvas (private subview)
        canvas.isUserInteractionEnabled = true
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content
    }
    /// Report the hosted content's size so SwiftUI lays the secret bubble out correctly.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        context.coordinator.host?.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity,
                                                          height: proposal.height ?? .infinity))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var host: UIHostingController<Content>? }
}
#endif

// MARK: - Screenshot / screen-recording protection

extension View {
    /// Exclude this view from screenshots / screen recordings while it's on screen. iOS hosts it
    /// inside a `UITextField` secure-entry layer (per-view); macOS marks the hosting window
    /// `sharingType = .none` (window-level). Plain no-op on Mac Catalyst.
    @ViewBuilder func screenshotProtected() -> some View {
        #if os(macOS) || (canImport(UIKit) && !targetEnvironment(macCatalyst))
        ScreenshotProtected { self }
        #else
        self
        #endif
    }
}

