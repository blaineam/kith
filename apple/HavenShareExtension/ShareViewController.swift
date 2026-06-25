import UIKit
import UniformTypeIdentifiers

/// A no-UI share extension: it extracts the shared text / link / photo / video, drops it into the
/// shared App Group inbox, opens the main app (`haven://share`), and completes. The app shows the
/// DM / post / story routing — the extension process is too short-lived to run the P2P stack.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await process() }
    }

    private func process() async {
        ShareInbox.ensureDir()
        var payload = ShareInbox.Payload()
        var fileIdx = 0
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            for provider in item.attachments ?? [] {
                // Order matters: prefer concrete media over a URL/text fallback the same item may vend.
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    if let src = await loadFile(provider, UTType.movie.identifier) {
                        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
                        let name = "vid-\(fileIdx).\(ext)"; fileIdx += 1
                        if let dst = ShareInbox.fileURL(name) {
                            try? FileManager.default.removeItem(at: dst)
                            try? FileManager.default.copyItem(at: src, to: dst)
                            payload.items.append(.init(kind: .video, file: name))
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, UTType.image.identifier) {
                        let name = "img-\(fileIdx).dat"; fileIdx += 1
                        if let dst = ShareInbox.fileURL(name) {
                            try? data.write(to: dst)
                            payload.items.append(.init(kind: .image, file: name))
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider) {
                        payload.items.append(.init(kind: .text, text: url.absoluteString))
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    if let s = await loadText(provider), !s.isEmpty {
                        payload.items.append(.init(kind: .text, text: s))
                    }
                }
            }
        }
        ShareInbox.writePayload(payload)
        await MainActor.run { openHost() }
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Provider loaders

    private func loadData(_ p: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            p.loadDataRepresentation(forTypeIdentifier: type) { d, _ in cont.resume(returning: d) }
        }
    }

    private func loadFile(_ p: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                // The vended URL is reclaimed when this callback returns — copy out first.
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
                cont.resume(returning: dest)
            }
        }
    }

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.text.identifier) { item, _ in
                cont.resume(returning: (item as? String) ?? (item as? NSString) as String?)
            }
        }
    }

    /// Open the host app. Extensions can't touch `UIApplication.shared`, so walk the responder chain
    /// for an object that implements `openURL:`.
    private func openHost() {
        guard let url = URL(string: "haven://share") else { return }
        let sel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) { _ = r.perform(sel, with: url); return }
            responder = r.next
        }
    }
}
