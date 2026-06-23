import ReplayKit
import CoreVideo

/// ReplayKit broadcast upload extension. The system captures the whole screen and feeds video
/// sample buffers here; we forward each frame to the Haven app through the shared App Group
/// container (see `BroadcastFrameSender` in Shared/BroadcastIPC.swift). The app, when in a call,
/// pushes those frames into its WebRTC screen track and renegotiates them to the mesh.
///
/// Audio sample buffers are ignored — call audio already flows over WebRTC's own mic track.
class SampleHandler: RPBroadcastSampleHandler {
    private let sender = BroadcastFrameSender()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sender.start()
    }

    override func broadcastFinished() {
        sender.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
        sender.send(pixelBuffer, timeStampNs: ts)
    }
}
