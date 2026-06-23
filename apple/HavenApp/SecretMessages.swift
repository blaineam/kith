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
                // Show the actual message. We rely on screenshot *detection* (re-conceal on
                // the notification below) rather than the secure-field layer hack, which on
                // current iOS hides the content from normal rendering too — so it showed blank.
                Text(text)
                    .font(.body)
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
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
/// Native macOS has no UITextField secure-entry screenshot exclusion; render content directly.
/// (Screenshot *detection* re-conceal also doesn't exist on macOS — secret bubbles still work
/// via tap-to-reveal + auto-conceal.)
struct ScreenshotProtected<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content }
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

        let field = UITextField()
        field.isSecureTextEntry = true
        guard let secure = field.subviews.first else { return host.view }
        secure.subviews.forEach { $0.removeFromSuperview() }
        secure.isUserInteractionEnabled = true
        secure.translatesAutoresizingMaskIntoConstraints = false
        secure.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: secure.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: secure.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: secure.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: secure.bottomAnchor),
        ])
        context.coordinator.host = host
        return secure
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var host: UIHostingController<Content>? }
}
#endif
