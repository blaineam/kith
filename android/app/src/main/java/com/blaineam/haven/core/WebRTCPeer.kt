package com.blaineam.haven.core

import android.util.Log
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack

/**
 * One pairwise WebRTC connection to a single mesh participant. DTLS-SRTP encrypts the media; SDP
 * and ICE are exchanged out-of-band over Haven's sealed channel (frames 16/17/18). The local
 * audio/video tracks are shared by CallManager across all peers.
 */
class WebRTCPeer(
    val peerHex: String,
    private val factory: PeerConnectionFactory,
    iceServers: List<PeerConnection.IceServer>,
    localAudio: AudioTrack?,
    localVideo: VideoTrack?,
    private val onLocalSdp: (type: String, sdp: String) -> Unit,
    private val onLocalIce: (candidate: String, mLineIndex: Int, mid: String?) -> Unit,
    private val onRemoteVideo: (VideoTrack?) -> Unit,
) {
    private val pendingRemote = ArrayList<IceCandidate>()
    var remoteSet = false; private set

    private val pc: PeerConnection? = factory.createPeerConnection(
        PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        },
        object : PeerConnection.Observer {
            override fun onIceCandidate(c: IceCandidate) = onLocalIce(c.sdp, c.sdpMLineIndex, c.sdpMid)
            override fun onTrack(transceiver: org.webrtc.RtpTransceiver) {
                (transceiver.receiver.track() as? VideoTrack)?.let { onRemoteVideo(it) }
            }
            override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {
                (receiver.track() as? VideoTrack)?.let { onRemoteVideo(it) }
            }
            override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) { Log.d(TAG, "$peerHex ice=$s") }
            override fun onConnectionChange(s: PeerConnection.PeerConnectionState) { Log.d(TAG, "$peerHex pc=$s") }
            override fun onSignalingChange(p: PeerConnection.SignalingState) {}
            override fun onIceGatheringChange(p: PeerConnection.IceGatheringState) {}
            override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
            override fun onIceConnectionReceivingChange(b: Boolean) {}
            override fun onAddStream(s: MediaStream) {}
            override fun onRemoveStream(s: MediaStream) {}
            override fun onDataChannel(d: DataChannel) {}
            override fun onRenegotiationNeeded() {}
        },
    )

    init {
        val streamIds = listOf("haven")
        localAudio?.let { pc?.addTrack(it, streamIds) }
        localVideo?.let { pc?.addTrack(it, streamIds) }
    }

    fun makeOffer() {
        val pc = pc ?: return
        pc.createOffer(object : SimpleSdp() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                pc.setLocalDescription(SimpleSdp(), sdp)
                onLocalSdp("offer", sdp.description)
            }
        }, mediaConstraints())
    }

    fun onRemoteOffer(sdp: String) {
        val pc = pc ?: return
        pc.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() {
                remoteSet = true; flushCandidates()
                pc.createAnswer(object : SimpleSdp() {
                    override fun onCreateSuccess(answer: SessionDescription) {
                        pc.setLocalDescription(SimpleSdp(), answer)
                        onLocalSdp("answer", answer.description)
                    }
                }, mediaConstraints())
            }
        }, SessionDescription(SessionDescription.Type.OFFER, sdp))
    }

    fun onRemoteAnswer(sdp: String) {
        pc?.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() { remoteSet = true; flushCandidates() }
        }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
    }

    fun addRemoteCandidate(candidate: String, mLineIndex: Int, mid: String?) {
        val ice = IceCandidate(mid, mLineIndex, candidate)
        if (remoteSet) pc?.addIceCandidate(ice) else pendingRemote.add(ice)
    }

    private fun flushCandidates() {
        pendingRemote.forEach { pc?.addIceCandidate(it) }
        pendingRemote.clear()
    }

    fun close() {
        runCatching { pc?.dispose() }
    }

    private fun mediaConstraints() = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "true"))
    }

    /** Most SdpObserver callbacks are no-ops; override only what's needed. */
    private open class SimpleSdp : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) { Log.w(TAG, "sdp create fail: $error") }
        override fun onSetFailure(error: String?) { Log.w(TAG, "sdp set fail: $error") }
    }

    companion object { private const val TAG = "WebRTCPeer" }
}
