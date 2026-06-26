package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

/**
 * Mesh group calls, the Android counterpart of the iOS CallManager. A call is a sessionId + a
 * roster of node-id hexes; every participant opens one [WebRTCPeer] to every other (full mesh,
 * no SFU). 1:1 is just a 2-person group. The lexicographically smaller hex offers (glare-free).
 * SDP/ICE ride frames 16/17/18 over Haven's sealed channel; media is DTLS-SRTP.
 *
 * In-app call UI (no Telecom yet) — matches the iOS Mac-Catalyst in-app overlay path.
 */
object CallManager {
    private const val TAG = "CallManager"

    // Observable UI state.
    val ringing = mutableStateOf(false)
    val connecting = mutableStateOf(false)
    val inCall = mutableStateOf(false)
    val peerName = mutableStateOf("")
    val micOn = mutableStateOf(true)
    val cameraOn = mutableStateOf(true)
    /** In-app minimized call (small floating tile + tap to restore), iOS parity. */
    val minimized = mutableStateOf(false)
    /** Other participants (hex), drives the video grid. */
    val participants: SnapshotStateList<String> = mutableStateListOf()
    /** Remote video track per participant, attached by the UI renderers. */
    val remoteVideo: SnapshotStateMap<String, VideoTrack?> = mutableStateMapOf()
    var localVideo: VideoTrack? = null; private set

    lateinit var eglBase: EglBase; private set

    private lateinit var appContext: Context
    private var myHex: String = ""
    private var factory: PeerConnectionFactory? = null
    private var audioTrack: AudioTrack? = null
    private var videoSource: VideoSource? = null
    private var capturer: CameraVideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null

    private var sessionId: String = ""
    private var isCaller = false
    private var mediaStarted = false
    private val roster = HashSet<String>()                 // includes me
    private val peers = HashMap<String, WebRTCPeer>()

    private val iceServers = listOf(
        PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
        PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
    )

    fun init(context: Context, myNodeHex: String) {
        if (this::appContext.isInitialized) { myHex = myNodeHex; return }
        appContext = context.applicationContext
        myHex = myNodeHex
        eglBase = EglBase.create()
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(appContext)
                .createInitializationOptions()
        )
        HavenNet.callRouter = { type, body -> handle(type, body) }
    }

    private fun ensureFactory(): PeerConnectionFactory =
        factory ?: PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory().also { factory = it }

    // ---- Starting / joining ----

    private fun invitees(): List<String> = (roster - myHex).sorted()
    private fun rosterCsv(): String = roster.sorted().joinToString(",")

    /** Start (or join) a call with the given OTHER participant hexes. 1:1 = [partnerHex]. */
    fun startCall(others: List<String>, name: String, session: String? = null) {
        if (inCall.value || ringing.value || connecting.value) {
            // Already in a call → treat as adding people.
            others.forEach { roster.add(it) }
            refreshParticipants(); return
        }
        sessionId = session ?: "and-${myHex.take(8)}-${System.nanoTime()}"
        roster.clear(); roster.addAll(others); roster.add(myHex)
        peerName.value = name
        isCaller = true
        connecting.value = true
        refreshParticipants()
        // Frame 21 group invite to everyone.
        val frame = CallWire.groupInvite(myHex, sessionId, name, rosterCsv())
        invitees().forEach { HavenNet.sendCallFrame(CallWire.GROUP_INVITE, frame, it) }
        startMesh()
    }

    fun accept() {
        ringing.value = false
        inCall.value = true
        invitees().forEach { HavenNet.sendCallFrame(CallWire.ACCEPT, CallWire.accept(myHex, sessionId), it) }
        startMesh()
        invitees().forEach { connectPeerIfNeeded(it) }
    }

    fun decline() = hangup()

    fun hangup() {
        invitees().forEach { HavenNet.sendCallFrame(CallWire.HANGUP, CallWire.hangup(myHex), it) }
        teardown()
    }

    // ---- Inbound signaling (from HavenNet.callRouter, on main) ----

    private fun handle(type: Int, body: ByteArray) {
        when (type) {
            CallWire.GROUP_INVITE -> handleGroupInvite(body)
            CallWire.INVITE -> CallWire.parseInviteName(body)?.let { (from, name) -> if (knownContact(from)) incoming(from, name, "legacy:$from", setOf(from, myHex)) }
            CallWire.ACCEPT -> handleAccept(body)
            CallWire.HANGUP -> handleHangup(body)
            CallWire.OFFER -> handleOffer(body)
            CallWire.ANSWER -> handleAnswer(body)
            CallWire.ICE -> handleIce(body)
        }
    }

    private fun handleGroupInvite(body: ByteArray) {
        val g = CallWire.parseGroupInvite(body) ?: return
        if (!knownContact(g.from)) return   // only contacts can invite you (F3)
        val members = (g.roster + g.from + myHex).toSet()
        if (inCall.value || ringing.value || connecting.value) {
            if (sessionId == g.sessionId) {
                val added = members - roster
                roster.addAll(members); refreshParticipants()
                if (mediaStarted) added.filter { it != myHex }.forEach { connectPeerIfNeeded(it) }
            }
            return
        }
        incoming(g.from, g.groupName, g.sessionId, members)
    }

    private fun incoming(from: String, name: String, session: String, members: Set<String>) {
        sessionId = session
        roster.clear(); roster.addAll(members)
        peerName.value = name
        isCaller = false
        ringing.value = true
        refreshParticipants()
    }

    private fun handleAccept(body: ByteArray) {
        val a = CallWire.parseAccept(body) ?: return
        if (!validSession(a.sessionId) || !knownContact(a.from)) return   // only a contact accepts (F3)
        connecting.value = false; inCall.value = true
        if (roster.add(a.from)) refreshParticipants()
        startMesh()
        connectPeerIfNeeded(a.from)
    }

    private fun handleHangup(body: ByteArray) {
        val from = CallWire.parseHangup(body) ?: return
        dropPeer(from)
        if ((roster - myHex).isEmpty()) teardown()
    }

    private fun handleOffer(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return   // only a participant negotiates (F3)
        if (!mediaStarted) startMesh()
        val sdp = CallSignal.decodeSdp(s.json) ?: return
        peerFor(s.from).onRemoteOffer(sdp.sdp)
    }

    private fun handleAnswer(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return
        val sdp = CallSignal.decodeSdp(s.json) ?: return
        peers[s.from]?.onRemoteAnswer(sdp.sdp)
    }

    private fun handleIce(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return
        val c = CallSignal.decodeCandidate(s.json) ?: return
        peerFor(s.from).addRemoteCandidate(c.candidate, c.mLineIndex, c.mid)
    }

    private fun validSession(sid: String) = sid == sessionId || sessionId.isEmpty()

    /// An unsealed call control frame's self-asserted sender must be a known contact — a stranger
    /// can't ring you, inject participants, or negotiate a call (audit F3, iOS parity).
    private fun knownContact(hex: String): Boolean = HavenNet.contacts.any { it.idHex == hex }

    // ---- Media + mesh ----

    private fun startMesh() {
        if (mediaStarted) return
        mediaStarted = true
        connecting.value = connecting.value && !inCall.value
        val f = ensureFactory()
        // Audio.
        val audioSource = f.createAudioSource(MediaConstraints())
        audioTrack = f.createAudioTrack("haven-audio", audioSource).apply { setEnabled(micOn.value) }
        // Video (front camera).
        startCamera(f)
        // Dial everyone we already know (callee dials too, glare rule prevents double offers).
        invitees().forEach { connectPeerIfNeeded(it) }
    }

    private fun startCamera(f: PeerConnectionFactory) {
        runCatching {
            val enumerator = Camera2Enumerator(appContext)
            val front = enumerator.deviceNames.firstOrNull { enumerator.isFrontFacing(it) }
                ?: enumerator.deviceNames.firstOrNull() ?: return
            val cap = enumerator.createCapturer(front, null) ?: return
            capturer = cap
            val src = f.createVideoSource(false); videoSource = src
            surfaceHelper = SurfaceTextureHelper.create("CaptureThread", eglBase.eglBaseContext)
            cap.initialize(surfaceHelper, appContext, src.capturerObserver)
            cap.startCapture(1280, 720, 30)
            localVideo = f.createVideoTrack("haven-video", src).apply { setEnabled(cameraOn.value) }
        }.onFailure { Log.w(TAG, "camera start failed", it) }
    }

    private fun connectPeerIfNeeded(peer: String): WebRTCPeer {
        val conn = peerFor(peer)
        if (myHex < peer && mediaStarted) conn.makeOffer()   // smaller hex offers
        return conn
    }

    private fun peerFor(peer: String): WebRTCPeer = peers.getOrPut(peer) {
        WebRTCPeer(
            peerHex = peer,
            factory = ensureFactory(),
            iceServers = iceServers,
            localAudio = audioTrack,
            localVideo = localVideo,
            onLocalSdp = { type, sdp ->
                val t = if (type == "offer") CallWire.OFFER else CallWire.ANSWER
                HavenNet.sendCallFrame(t, CallWire.signal(myHex, sessionId, CallSignal.encodeSdp(type, sdp)), peer)
            },
            onLocalIce = { cand, m, mid ->
                HavenNet.sendCallFrame(CallWire.ICE, CallWire.signal(myHex, sessionId, CallSignal.encodeCandidate(cand, m, mid)), peer)
            },
            onRemoteVideo = { track -> remoteVideo[peer] = track },
        )
    }

    private fun dropPeer(peer: String) {
        peers.remove(peer)?.close()
        roster.remove(peer)
        remoteVideo.remove(peer)
        refreshParticipants()
    }

    private fun refreshParticipants() {
        val others = (roster - myHex).sorted()
        participants.clear(); participants.addAll(others)
    }

    // ---- Controls ----

    fun toggleMic() { micOn.value = !micOn.value; audioTrack?.setEnabled(micOn.value) }
    fun toggleCamera() { cameraOn.value = !cameraOn.value; localVideo?.setEnabled(cameraOn.value) }
    fun switchCamera() { capturer?.switchCamera(null) }

    private fun teardown() {
        peers.values.forEach { it.close() }; peers.clear()
        runCatching { capturer?.stopCapture() }
        runCatching { capturer?.dispose() }; capturer = null
        runCatching { surfaceHelper?.dispose() }; surfaceHelper = null
        localVideo = null
        remoteVideo.clear(); participants.clear(); roster.clear()
        sessionId = ""; mediaStarted = false; isCaller = false
        ringing.value = false; connecting.value = false; inCall.value = false; minimized.value = false
        peerName.value = ""
    }
}
