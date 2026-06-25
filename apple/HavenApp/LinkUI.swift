import SwiftUI
import WebKit
import LinkPresentation
import UniformTypeIdentifiers

/// Drives the in-app browser. Anywhere in the app, call `LinkPresenter.shared.open(...)` to
/// open a link inside Haven (so people can share links freely without leaving the app).
@MainActor
final class LinkPresenter: ObservableObject {
    static let shared = LinkPresenter()
    @Published var presented: PresentedURL?

    /// Open a link string in the in-app browser, normalizing a bare host into https://.
    func open(_ string: String) {
        guard let url = Self.normalized(string) else { return }
        presented = PresentedURL(url: url)
    }

    /// Turn user/profile text into a real URL: add https:// if no scheme, reject non-web.
    static func normalized(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct PresentedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Find the http(s) links inside a block of body text (for inline previews + tappable text).
enum LinkScanner {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func urls(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match -> URL? in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }
}

// MARK: - In-app browser

/// A WKWebView wrapper with navigation state surfaced for the chrome (back/forward/address).
#if !os(macOS)
struct WebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        model.bind(web)
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WebViewModel
        init(_ model: WebViewModel) { self.model = model }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { model.refresh(w, loading: true) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { model.refresh(w, loading: false) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { model.refresh(w, loading: false) }
    }
}
#else
struct WebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        model.bind(web)
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WebViewModel
        init(_ model: WebViewModel) { self.model = model }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { model.refresh(w, loading: true) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { model.refresh(w, loading: false) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { model.refresh(w, loading: false) }
    }
}
#endif

@MainActor
final class WebViewModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentHost = ""
    private weak var web: WKWebView?

    func bind(_ web: WKWebView) { self.web = web }
    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }
    func reload() { web?.reload() }

    func refresh(_ web: WKWebView, loading: Bool) {
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        isLoading = loading
        currentHost = web.url?.host ?? web.url?.absoluteString ?? currentHost
    }
}

/// The in-app browser sheet: an address bar showing the current site, back/forward, reload,
/// open-in-Safari, and a close button.
struct InAppBrowserView: View {
    let url: URL
    @StateObject private var model = WebViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            #if !os(macOS)
            WebView(url: url, model: model)
                // Don't draw under the bottom toolbar — that made the nav controls sit on top of
                // the page content. Respecting the bottom safe area keeps the page above the bar.
                .havenInlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: model.currentHost.isEmpty ? "globe" : "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(model.currentHost.isEmpty ? url.host ?? url.absoluteString : model.currentHost)
                                .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    ToolbarItem(placement: .havenLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canGoBack)
                        Spacer()
                        Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canGoForward)
                        Spacer()
                        if model.isLoading { ProgressView() } else {
                            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Spacer()
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .tint(HavenTheme.pink)
            #else
            WebView(url: url, model: model)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: model.currentHost.isEmpty ? "globe" : "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(model.currentHost.isEmpty ? url.host ?? url.absoluteString : model.currentHost)
                                .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    ToolbarItemGroup {
                        Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canGoBack)
                        Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canGoForward)
                        if model.isLoading { ProgressView() } else {
                            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .tint(HavenTheme.pink)
            #endif
        }
    }
}

// MARK: - Rich link preview (Open Graph) card

/// A tappable Open Graph preview for a URL, rendered with the system's `LPLinkView` (which
/// fetches title/icon/image on-device). Tapping opens it in the in-app browser.
struct LinkPreviewCard: View {
    let url: URL

    var body: some View {
        Button { LinkPresenter.shared.open(url.absoluteString) } label: {
            LinkPreviewRepresentable(url: url)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))   // never bleed past the bubble edge
        }
        .buttonStyle(.plain)
    }
}

#if !os(macOS)
private struct LinkPreviewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        // LPLinkView reports a large intrinsic width and otherwise ignores the SwiftUI frame, so it
        // bled past the bubble/screen edge. Let it yield horizontally to the proposed width.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Show a fast placeholder, then fetch real Open Graph metadata on-device.
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async {
                view.metadata = metadata
                view.invalidateIntrinsicContentSize()
            }
        }
        return view
    }
    func updateUIView(_ view: LPLinkView, context: Context) {}

    /// Constrain the card to the proposed width (the caller's `.frame(maxWidth:)`) and compute the
    /// matching height — without this LPLinkView lays out at its full intrinsic width and overflows.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let fitted = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: max(fitted.height, 1))
    }
}
#else
private struct LinkPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Show a fast placeholder, then fetch real Open Graph metadata on-device.
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async {
                view.metadata = metadata
                view.invalidateIntrinsicContentSize()
            }
        }
        return view
    }
    func updateNSView(_ view: LPLinkView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LPLinkView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        let fitted = nsView.fittingSize
        let ratio = fitted.width > 0 ? fitted.height / fitted.width : 0.6
        return CGSize(width: width, height: max(width * ratio, 1))
    }
}
#endif

/// Body text that makes any http(s) links tappable (opening the in-app browser) and renders a
/// rich Open Graph preview card for the first link. Use anywhere a post/comment body is shown.
struct LinkedText: View {
    let text: String
    var font: Font = .body
    var showsPreview: Bool = true

    var body: some View {
        let urls = LinkScanner.urls(in: text)
        VStack(alignment: .leading, spacing: 8) {
            if !text.isEmpty {
                Text(Self.attributed(text))
                    .font(font)
                    // Route link taps into the in-app browser instead of leaving the app.
                    .environment(\.openURL, OpenURLAction { url in
                        LinkPresenter.shared.open(url.absoluteString); return .handled
                    })
            }
            if showsPreview, let first = urls.first {
                LinkPreviewCard(url: first)
            }
        }
    }

    private static func attributed(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        let ns = s as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attr }
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let r = Range(m.range, in: attr) else { continue }
            attr[r].link = url
            attr[r].foregroundColor = HavenTheme.pink
            attr[r].underlineStyle = .single
        }
        return attr
    }
}
