import Foundation

/// Adapts the Rust `InboundListener` callback to a Swift closure. The Rust node calls
/// `onInbound` (off the main thread) for each inbound frame; FeedStore handles it.
final class InboundBridge: InboundListener {
    private let onData: (Data) -> Void
    init(onData: @escaping (Data) -> Void) { self.onData = onData }
    func onInbound(payload: Data) { onData(payload) }
}
