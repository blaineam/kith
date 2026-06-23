import Foundation
import CoreVideo

#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreMedia
import CoreImage

/// Shared constants + frame transport for the iOS ReplayKit screen-broadcast path.
///
/// The broadcast upload extension and the main app are separate processes. They communicate through
/// a file in a shared **App Group** container: the extension writes one captured frame at a time
/// into a memory-mapped buffer and fires a Darwin notification; the app, listening for that
/// notification, maps the same file and reads the frame, then hands the resulting `CVPixelBuffer`
/// to WebRTC.
///
/// This is intentionally a *latest-frame* transport (single slot, newest wins) — screen sharing is
/// real-time, so dropping a stale frame under back-pressure is correct.
enum BroadcastIPC {
    /// MUST match the App Group added to both the app and the extension entitlements.
    static let appGroup = "group.com.blaineam.kith"

    /// Darwin notification names (process-wide, no payload — just a wake signal).
    static let frameReadyNote = "com.blaineam.kith.broadcast.frame" as CFString
    static let startedNote    = "com.blaineam.kith.broadcast.started" as CFString
    static let stoppedNote    = "com.blaineam.kith.broadcast.stopped" as CFString

    /// The shared frame file inside the App Group container.
    static func frameFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("broadcast_frame.bin")
    }

    /// Header layout at the top of the shared file (all little-endian, fixed offsets):
    ///   [0..3]  width   (UInt32)
    ///   [4..7]  height  (UInt32)
    ///   [8..11] bytesPerRow (UInt32)
    ///   [12..15] generation (UInt32, bumped each write)
    ///   [16..23] timestampNs (Int64)
    /// followed by `height * bytesPerRow` bytes of BGRA pixel data.
    static let headerSize = 24

    /// A generous ceiling so the mmap'd file never needs to grow mid-broadcast (≈4K BGRA + header).
    static let maxFrameBytes = 4096 * 2304 * 4 + headerSize
}

/// App side: maps the shared file, listens for the extension's Darwin notifications, and reconstructs
/// a `CVPixelBuffer` per frame.
final class BroadcastFrameReceiver {
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    var onStop: (() -> Void)?

    private var fd: Int32 = -1
    private var map: UnsafeMutableRawPointer?
    private var mappedLength = 0
    private var lastGeneration: UInt32 = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    func start() {
        guard let url = BroadcastIPC.frameFileURL() else { return }
        // Ensure the file exists at full size so both sides map the same region.
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        var st = stat()
        fstat(fd, &st)
        mappedLength = max(Int(st.st_size), BroadcastIPC.headerSize)
        map = mmap(nil, mappedLength, PROT_READ, MAP_SHARED, fd, 0)
        if map == MAP_FAILED { map = nil }

        registerDarwinObserver(BroadcastIPC.frameReadyNote) { [weak self] in self?.readFrame() }
        registerDarwinObserver(BroadcastIPC.stoppedNote) { [weak self] in self?.onStop?() }
    }

    func stop() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        if let map, mappedLength > 0 { munmap(map, mappedLength) }
        map = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func registerDarwinObserver(_ name: CFString, _ handler: @escaping () -> Void) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        CFNotificationCenterAddObserver(center, box, { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(observer).takeUnretainedValue()
            box.handler()
        }, name, nil, .deliverImmediately)
    }

    private final class HandlerBox { let handler: () -> Void; init(_ h: @escaping () -> Void) { handler = h } }

    private func readFrame() {
        guard let map else { return }
        let header = map.bindMemory(to: UInt32.self, capacity: 6)
        let width = Int(header[0]); let height = Int(header[1]); let bpr = Int(header[2])
        let generation = header[3]
        guard generation != lastGeneration, width > 0, height > 0, bpr > 0 else { return }
        lastGeneration = generation
        let tsPtr = map.advanced(by: 16).assumingMemoryBound(to: Int64.self)
        let ts = tsPtr.pointee
        let dataBytes = height * bpr
        guard BroadcastIPC.headerSize + dataBytes <= mappedLength else { return }

        guard let pb = makePixelBuffer(width: width, height: height) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dst = CVPixelBufferGetBaseAddress(pb) {
            let dstBpr = CVPixelBufferGetBytesPerRow(pb)
            let src = map.advanced(by: BroadcastIPC.headerSize)
            // Copy row by row (source and dest strides may differ).
            let rowBytes = min(bpr, dstBpr)
            for y in 0..<height {
                memcpy(dst.advanced(by: y * dstBpr), src.advanced(by: y * bpr), rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        onFrame?(pb, ts)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            pixelBufferPool = pool; poolWidth = width; poolHeight = height
        }
        guard let pool = pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

/// Extension side: maps the shared file and writes the newest frame, then fires the Darwin
/// notification. Used by the broadcast upload extension's `SampleHandler`.
final class BroadcastFrameSender {
    private var fd: Int32 = -1
    private var map: UnsafeMutableRawPointer?
    private var mappedLength = 0
    private var generation: UInt32 = 0
    // ReplayKit delivers YUV (420 biplanar) frames, but the IPC + app read BGRA. Convert each frame
    // to BGRA here, reusing one Metal CIContext + one output buffer so the extension stays under its
    // tight memory budget. Without this the app read plane-0 luma as BGRA → the garbled grayscale
    // diagonal-shear image.
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var bgraBuffer: CVPixelBuffer?
    private var bgraW = 0
    private var bgraH = 0

    func start() {
        guard let url = BroadcastIPC.frameFileURL() else { return }
        let path = url.path
        // Pre-size the file so the mmap covers the largest possible frame.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        ftruncate(fd, off_t(BroadcastIPC.maxFrameBytes))
        mappedLength = BroadcastIPC.maxFrameBytes
        map = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        if map == MAP_FAILED { map = nil }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(BroadcastIPC.startedNote),
                                             nil, nil, true)
    }

    func stop() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(BroadcastIPC.stoppedNote),
                                             nil, nil, true)
        if let map, mappedLength > 0 { munmap(map, mappedLength) }
        map = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    func send(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        guard let map else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Convert anything that isn't already BGRA (ReplayKit gives us 420 YUV) into BGRA so the
        // app's BGRA reader is correct. Reuse one output buffer keyed on the frame size.
        let bgra: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            bgra = pixelBuffer
        } else {
            if bgraBuffer == nil || bgraW != width || bgraH != height {
                var pb: CVPixelBuffer?
                let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                bgraBuffer = pb; bgraW = width; bgraH = height
            }
            guard let out = bgraBuffer else { return }
            ciContext.render(CIImage(cvPixelBuffer: pixelBuffer), to: out)
            bgra = out
        }

        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(bgra)
        let dataBytes = height * bpr
        guard BroadcastIPC.headerSize + dataBytes <= mappedLength,
              let src = CVPixelBufferGetBaseAddress(bgra) else { return }
        // Copy pixels first, then the header (generation last so the reader never sees a torn frame).
        memcpy(map.advanced(by: BroadcastIPC.headerSize), src, dataBytes)
        let header = map.bindMemory(to: UInt32.self, capacity: 6)
        header[0] = UInt32(width); header[1] = UInt32(height); header[2] = UInt32(bpr)
        map.advanced(by: 16).assumingMemoryBound(to: Int64.self).pointee = timeStampNs
        generation &+= 1
        header[3] = generation
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(BroadcastIPC.frameReadyNote),
                                             nil, nil, true)
    }
}
#endif
