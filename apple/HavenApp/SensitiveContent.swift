import SwiftUI
import SensitiveContentAnalysis

/// On-device sensitive-content detection (Apple's `SensitiveContentAnalysis`, iOS 17 / macOS 14).
/// It runs ONLY when the user has turned on "Sensitive Content Warning" in system Settings, and
/// everything happens on the device — nothing about the media leaves Haven. We use it to blur
/// **incoming** photos/videos that are flagged until the viewer chooses to reveal them.
///
/// Apple-platforms only — Android/Windows/Linux have no equivalent system API and would need a
/// bundled on-device model.
@MainActor
final class SensitiveContentScanner: ObservableObject {
    static let shared = SensitiveContentScanner()

    /// Results cached by media ref so the feed never re-analyzes the same item.
    private var cache: [String: Bool] = [:]

    /// True only when the user has enabled "Sensitive Content Warning" system-wide. When off we do
    /// no analysis at all (zero cost, and we never blur).
    var isEnabled: Bool {
        SCSensitivityAnalyzer().analysisPolicy != .disabled
    }

    /// Whether the media at `ref` is flagged sensitive. Cheap + cached; returns false when the
    /// feature is off, the media isn't loaded yet, or analysis fails.
    func isSensitive(ref: String) async -> Bool {
        if let cached = cache[ref] { return cached }
        let analyzer = SCSensitivityAnalyzer()
        guard analyzer.analysisPolicy != .disabled,
              let item = MediaStore.shared.item(ref),
              let cg = item.image?.cgImage else { return false }
        // Analyze the still (a video's `image` is its poster/first frame — the same thumbnail the
        // tile shows). Keeps the path simple + identical for photos and videos.
        var result = false
        do { result = try await analyzer.analyzeImage(cg).isSensitive }
        catch { result = false }   // never block content on an analyzer error
        cache[ref] = result
        return result
    }
}

/// Blurs a piece of media until the viewer taps to reveal it, IF the system "Sensitive Content
/// Warning" setting is on and the on-device analyzer flags it. Apply to **received** media only
/// (`scan: !item.isMe`) — you don't need warning about your own posts.
struct SensitiveContentGuard: ViewModifier {
    let ref: String
    /// The circle this media belongs to — federated flags are per-circle.
    let circleId: String
    /// Only scan received media; pass `false` for the viewer's own content.
    var scan: Bool = true
    var cornerRadius: CGFloat = 10

    @ObservedObject private var scanner = SensitiveContentScanner.shared
    @ObservedObject private var feed = FeedStore.shared
    @State private var localSensitive = false
    @State private var revealed = false

    /// Sensitive if MY device's SCA flagged it OR any circle member flagged it (the federated set —
    /// this is what protects viewers whose platform has no SCA).
    private var sensitive: Bool {
        localSensitive || feed.sensitiveRefs(circleId: circleId).contains(ref)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if sensitive && !revealed {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        VStack(spacing: 5) {
                            Image(systemName: "eye.slash.fill").font(.title3)
                            Text("Sensitive Content").font(.caption.weight(.semibold))
                            Text("Tap to view").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { revealed = true } }
                    .transition(.opacity)
                }
            }
            .task(id: ref) {
                guard scan, scanner.isEnabled else { return }
                if await scanner.isSensitive(ref: ref) {
                    localSensitive = true
                    // Tell the whole circle so members without SCA blur it too (deduped).
                    feed.flagSensitive(circleId: circleId, ref: ref)
                }
            }
    }
}

extension View {
    /// Blur sensitive media until tapped — flagged either by this device's Sensitive Content
    /// Analysis or by any circle member's federated flag. See `SensitiveContentGuard`.
    func sensitiveContentGuard(ref: String, circleId: String, scan: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(SensitiveContentGuard(ref: ref, circleId: circleId, scan: scan, cornerRadius: cornerRadius))
    }
}
