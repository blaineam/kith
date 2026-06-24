package com.blaineam.haven.core

import android.content.Context
import android.util.Base64
import android.util.Log
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.HavenNode
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.InboundListener
import uniffi.haven_ffi.RelayClient
import uniffi.haven_ffi.parseLink
import java.io.File
import java.security.MessageDigest

private const val TAG = "HavenNet"
const val DEFAULT_CIRCLE = "default"

/** A known contact (their verified identity + display name). */
data class Contact(val idHex: String, val name: String, val verifyHex: String)

/** Someone who said hello but we haven't approved yet. */
data class PendingRequest(val idHex: String, val name: String, val verifyHex: String, val bundle: ByteArray)

/**
 * The Android counterpart of the iOS FeedStore networking core: owns the [HavenSocial] engine
 * and the [HavenNode] iroh transport, speaks the byte-exact [Wire] protocol, and drives the
 * Hello/Event handshake so an Android phone forms circles and exchanges posts with an iPhone.
 *
 * Connect model (one approval, MITM-guarded):
 *   - Scanning a friend's QR records "I initiated <node>, expect <verifyHex>" and sends them a
 *     Hello (carrying our bundle) over iroh.
 *   - An inbound Hello from a node we initiated, whose bundle hash matches, is auto-accepted.
 *   - An inbound Hello we did NOT initiate becomes a [pending] request for the user to approve.
 */
object HavenNet : InboundListener {
    private lateinit var appContext: Context
    private lateinit var core: HavenCore
    private lateinit var profile: ProfileStore
    private lateinit var social: HavenSocial
    private var node: HavenNode? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Observable UI state.
    val contacts: SnapshotStateList<Contact> = mutableStateListOf()
    val pending: SnapshotStateList<PendingRequest> = mutableStateListOf()
    val blocked: SnapshotStateList<String> = mutableStateListOf()
    var internetActive = mutableStateOf(false); private set
    var started = mutableStateOf(false); private set
    var feedVersion = mutableStateOf(0); private set   // bump to recompose the feed
    var relayActive = mutableStateOf(false); private set
    @Volatile var isForeground = false   // set by the UI lifecycle; suppresses notifications when open   // true once a mailbox put/get succeeds

    // Circle relay/mailbox: circleId -> ORDERED list of relay node hexes. Posts are mirrored to
    // every relay (redundancy) and read from all of them (graceful fallback if one is down) —
    // parity with the desktop `relays: HashMap<String, Vec<String>>`.
    private val relayNodes = HashMap<String, MutableList<String>>()
    private val relayClients = HashMap<String, RelayClient>()
    private val relayMutex = Mutex()
    private val seenMailbox = HashSet<String>()

    /**
     * Per-relay exponential-backoff health (5s → 5m), keyed by node hex — drives graceful
     * fallback. A relay that fails to connect/put/list/get is parked in a backoff window so we
     * stop hammering a dead relay and quietly use the others, then retry it later so a relay that
     * comes back is picked up again automatically. Mirror of desktop relayhealth.rs.
     */
    private class RelayHealth {
        var fails = 0
        var nextRetryMs = 0L   // earliest epoch-ms we'll try again; 0 = available now
        fun available(nowMs: Long): Boolean = nowMs >= nextRetryMs
        fun recordSuccess() { fails = 0; nextRetryMs = 0L }
        fun recordFailure(nowMs: Long) {
            fails += 1
            val shift = minOf(fails - 1, 6)   // cap the exponent so the shift never overflows
            val backoff = minOf(BASE_BACKOFF_MS shl shift, MAX_BACKOFF_MS)
            nextRetryMs = nowMs + backoff
        }
        companion object {
            const val BASE_BACKOFF_MS = 5_000L      // first failure → 5s cool-off
            const val MAX_BACKOFF_MS = 300_000L     // capped at 5 minutes
        }
    }
    private val relayHealth = HashMap<String, RelayHealth>()

    // node ids we initiated a connect to (scanned their QR) → expected verify hash.
    private val initiated = HashMap<String, String>()

    private val stateFile: File get() = File(appContext.filesDir, "haven_social_state.bin")
    private val prefs get() = appContext.getSharedPreferences("haven.contacts", Context.MODE_PRIVATE)

    @Volatile private var ready = false

    @Synchronized
    fun init(context: Context) {
        if (ready) return   // atomic: never expose half-initialized state to a concurrent caller
        appContext = context.applicationContext
        // Must run before any iroh/TLS networking, or the node panics on Android.
        NativeBridge.ensureAndroidContext(appContext)
        core = HavenCore.get(appContext)
        profile = ProfileStore.get(appContext)
        social = HavenSocial(core.seed)
        LocalMedia.init(appContext)
        Presign.init(appContext)
        CircleLock.init(appContext)
        restoreState()
        loadContacts()
        loadBlocked()
        loadRelayNodes()
        ready = true
    }

    /** Start the iroh node and begin syncing. Safe to call repeatedly. */
    fun start() {
        if (node != null) return
        scope.launch {
            try {
                node = HavenNode.start(core.seed, this@HavenNet)
                withContext(Dispatchers.Main) { started.value = true }
                Log.i(TAG, "node started: ${node?.nodeIdHex()}")
                syncWithContacts()
                pollMailbox()
                requestMissingMedia()   // back-fill media for posts already in the feed
            } catch (e: Throwable) {
                Log.e(TAG, "node start failed", e)
            }
        }
        startMailboxLoop()
    }

    /** Poll the circle relay/mailbox every 15s so posts arrive even when peers aren't both online. */
    private var loopStarted = false
    private fun startMailboxLoop() {
        if (loopStarted) return
        loopStarted = true
        scope.launch {
            while (true) {
                delay(15_000)
                runCatching { pollMailbox() }
            }
        }
    }

    val nodeIdHex: String get() = core.nodeIdHex
    fun inviteUri(): String = core.inviteUri()

    // ---- Multi-circle ----

    val activeCircle = mutableStateOf(DEFAULT_CIRCLE)
    var circlesVersion = mutableStateOf(0); private set

    /** Non-DM circles, for the feed switcher. */
    fun feedCircles(): List<uniffi.haven_ffi.CircleInfoFfi> =
        runCatching { social.circles().filter { !it.id.startsWith("dm:") } }.getOrDefault(emptyList())

    fun circleName(id: String): String =
        runCatching { social.circles().firstOrNull { it.id == id }?.name }.getOrNull() ?: "My Circle"

    fun createCircle(name: String): String {
        val id = "circle-${nodeIdHex.take(8)}-${System.nanoTime()}"
        runCatching { social.createCircle(id, name) }
        persist(); bumpCircles()
        activeCircle.value = id
        return id
    }

    fun renameCircle(id: String, name: String) {
        runCatching { social.renameCircle(id, name) }; persist(); bumpCircles()
    }

    fun leaveCircle(id: String) {
        if (id == DEFAULT_CIRCLE) return
        runCatching { social.leaveCircle(id) }
        if (activeCircle.value == id) activeCircle.value = DEFAULT_CIRCLE
        persist(); bumpCircles()
    }

    /** Add an existing contact to a circle + greet them there so it forms on their side. */
    fun addToCircle(circleId: String, contactIdHex: String) {
        runCatching { social.addExistingToCircle(circleId, contactIdHex) }
        persist(); bumpCircles()
        sendHello(circleId, contactIdHex)
    }

    fun setActiveCircle(id: String) { activeCircle.value = id }

    private fun bumpCircles() { scope.launch(Dispatchers.Main) { circlesVersion.value++ } }

    /** Resolve a feed item's short author id (8 hex) to a contact's display name. */
    fun displayName(authorShort: String): String =
        contacts.firstOrNull { it.idHex.startsWith(authorShort) }?.name
            ?: if (authorShort.length >= 6) "Someone (${authorShort.take(6)})" else authorShort

    // ---- Inbound dispatch (called off-main by the Rust node) -----------------------------

    override fun onInbound(payload: ByteArray) {
        if (payload.isEmpty()) return
        val type = payload[0].toInt() and 0xFF
        val body = payload.copyOfRange(1, payload.size)
        // Call frames lead with a 64-char sender hex — drop blocked senders early (parity with iOS).
        if (type in intArrayOf(Wire.MEDIA_REQ, CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE)) {
            if (body.size >= 64) {
                val head = String(body.copyOfRange(0, 64), Charsets.UTF_8)
                if (head.length == 64 && blocked.contains(head)) return
            }
        }
        scope.launch {
            withContext(Dispatchers.Main) { internetActive.value = true }
            when (type) {
                Wire.HELLO -> handleHello(body)
                Wire.EVENT -> handleEvent(body)
                Wire.RELAY_NODE -> handleRelayNode(body)
                Wire.PRESIGN -> handlePresignBootstrap(body)
                Wire.MEDIA_REQ -> handleMediaRequest(body)
                Wire.MEDIA_CHUNK -> handleMediaChunk(body)
                CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE ->
                    withContext(Dispatchers.Main) { callRouter?.invoke(type, body) }
                else -> Log.d(TAG, "ignoring frame type $type (not yet handled)")
            }
        }
    }

    /** CallManager registers here to receive call frames (kept as a hook to avoid a hard dependency). */
    var callRouter: ((type: Int, body: ByteArray) -> Unit)? = null

    /** Send a call signaling frame to one node (used by CallManager). */
    fun sendCallFrame(type: Int, payload: ByteArray, toNodeHex: String) = sendFrame(type, payload, toNodeHex)

    private fun handleHello(payload: ByteArray) {
        val hello = Wire.parseHello(payload) ?: return
        val idHex = nodeHex(hello.bundle)
        if (blocked.contains(idHex)) return   // a blocked node can't handshake back in
        val actualVerify = runCatching { social.bundleVerificationHex(hello.bundle) }.getOrNull() ?: return
        val name = runCatching { social.verifyProfile(hello.bundle, hello.signedProfile) }.getOrNull() ?: "Someone"
        // Capture the full profile card (avatar + emoji) so the feed/people/story-tray show real photos.
        runCatching { social.verifyProfileCard(hello.bundle, hello.signedProfile) }.getOrNull()
            ?.let { AvatarStore.put(idHex, it.avatar, it.emoji) }

        // DM circles encode both full node ids — only those two may ever join (MITM/contamination guard).
        if (hello.circleId.startsWith("dm:") && !dmAllows(hello.circleId, idHex)) return
        // A verified Hello forms the circle on our side if we don't have it yet (matches iOS).
        runCatching { social.createCircle(hello.circleId, hello.circleName) }

        val expected = initiated[idHex]
        if (expected != null) {
            // We scanned them first — auto-accept iff the bundle hash matches what the QR promised.
            if (expected.isNotEmpty() && expected != actualVerify) {
                Log.w(TAG, "verify mismatch for $idHex — dropping (possible MITM)")
                return
            }
            acceptContact(hello.circleId, hello.bundle, idHex, name, actualVerify, helloBack = true)
            initiated.remove(idHex)
            return
        }
        if (contacts.any { it.idHex == idHex }) {
            // Already a contact (e.g. their Hello-back) — make sure their bundle is in the circle.
            runCatching { social.addContactBundle(hello.circleId, hello.bundle) }
            return
        }
        // Unknown sender on a non-DM circle → a request to approve.
        if (!hello.circleId.startsWith("dm:")) {
            scope.launch(Dispatchers.Main) {
                if (pending.none { it.idHex == idHex }) {
                    pending.add(PendingRequest(idHex, name, actualVerify, hello.bundle))
                }
            }
        }
    }

    // ---- DMs (a DM is a private 2-person circle, id encodes both node ids) ----------------

    /** Deterministic DM circle id — identical on both sides (full sorted node ids). */
    fun dmCircleId(idHex: String): String {
        val pair = listOf(nodeIdHex, idHex).sorted()
        return "dm:${pair[0]}-${pair[1]}"
    }

    private fun dmAllows(circleId: String, nodeHex: String): Boolean {
        val parts = circleId.removePrefix("dm:").split("-")
        return parts.size == 2 && parts.contains(nodeHex)
    }

    /** Open (or create) a DM with a known contact; returns the dm circle id. */
    fun startDm(contact: Contact): String {
        val id = dmCircleId(contact.idHex)
        runCatching { social.createCircle(id, contact.name) }
        runCatching { social.addExistingToCircle(id, contact.idHex) }
        persist()
        sendHello(id, contact.idHex)
        return id
    }

    /** The messages of a circle (a DM thread), oldest→newest for chat display. */
    fun messages(circleId: String): List<uniffi.haven_ffi.FeedItemFfi> =
        runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList()).sortedBy { it.createdAt }

    /** Send a text DM into a circle and deliver it to the partner. */
    fun sendDm(circleId: String, body: String, media: List<String> = emptyList()) {
        if (body.isBlank() && media.isEmpty()) return
        val env = runCatching {
            social.post(circleId, body, media, null, null, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
        scope.launch { media.forEach { uploadMedia(circleId, it) } }
    }

    /**
     * Reply to someone's story → opens a DM with them and ATTACHES the story's media (re-sealed to
     * the DM circle) so the author knows exactly which story you mean. Returns the DM circle id.
     */
    fun replyToStory(authorShort: String, storyMediaRef: String?, text: String): String? {
        val contact = contacts.firstOrNull { it.idHex.startsWith(authorShort) } ?: return null
        val dmCircle = startDm(contact)
        val media = storyMediaRef?.let { ref ->
            LocalMedia.loadAnyCircle(ref)?.let { listOf(LocalMedia.store(dmCircle, it, isVideo = LocalMedia.isVideo(ref))) }
        } ?: emptyList()
        sendDm(dmCircle, text, media)
        return dmCircle
    }

    private fun handleEvent(payload: ByteArray) {
        val ev = Wire.parseEvent(payload) ?: return
        val changed = runCatching { social.receive(ev.circleId, ev.envelope) }.getOrDefault(false)
        if (changed) {
            persist()
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()   // fetch any photos/videos the new post references
            notifyInbound(ev.circleId)
        }
    }

    /** Post a local notification for new inbound content when the app isn't foreground. */
    private fun notifyInbound(circleId: String) {
        if (isForeground) return
        val isDm = circleId.startsWith("dm:")
        Notifications.notify(
            appContext,
            title = if (isDm) "New message" else "New in your circle",
            body = if (isDm) "You have a new Haven message" else "Someone posted in your circle",
        )
    }

    // ---- Outbound ------------------------------------------------------------------------

    /** Begin a connect from a scanned/pasted haven:// invite. */
    fun connectByLink(uri: String): Boolean {
        val info = runCatching { parseLink(uri.trim()) }.getOrNull() ?: return false
        initiated[info.idHex] = info.verificationHex
        sendHello(DEFAULT_CIRCLE, info.idHex)
        return true
    }

    /** Approve a pending request: add them, persist, and Hello back so they auto-accept us. */
    fun approve(req: PendingRequest) {
        acceptContact(DEFAULT_CIRCLE, req.bundle, req.idHex, req.name, req.verifyHex, helloBack = true)
        pending.removeAll { it.idHex == req.idHex }
    }

    fun dismiss(req: PendingRequest) { pending.removeAll { it.idHex == req.idHex } }

    /** Block a node: purge from every circle, drop from contacts, ignore future frames. */
    fun block(idHex: String) {
        runCatching { social.blockMember(idHex) }
        contacts.removeAll { it.idHex == idHex }
        pending.removeAll { it.idHex == idHex }
        if (blocked.none { it == idHex }) blocked.add(idHex)
        saveContacts(); saveBlocked(); persist()
    }

    /** Remove someone from the current circle WITHOUT blocking them (parity with iOS). */
    fun removeFromCircle(idHex: String) {
        runCatching { social.removeFromCircle(activeCircle.value, idHex) }
        feedVersion.value++; circlesVersion.value++; persist()
    }

    fun unblock(idHex: String) {
        blocked.removeAll { it == idHex }
        saveBlocked()
    }

    private fun acceptContact(
        circleId: String, bundle: ByteArray, idHex: String, name: String, verifyHex: String, helloBack: Boolean,
    ) {
        runCatching { social.addContactBundle(circleId, bundle) }
        scope.launch(Dispatchers.Main) {
            if (contacts.none { it.idHex == idHex }) contacts.add(Contact(idHex, name, verifyHex))
            saveContacts()
        }
        persist()
        if (helloBack) sendHello(circleId, idHex)
    }

    /** Send our Hello + (optionally) back-fill this circle's events to one node. */
    private fun sendHello(circleId: String, toNodeHex: String) {
        val hello = helloPayload(circleId) ?: return
        sendFrame(Wire.HELLO, hello, toNodeHex)
        val envs = runCatching { social.syncEnvelopes(circleId) }.getOrDefault(emptyList())
        for (env in envs) sendFrame(Wire.EVENT, Wire.eventPayload(circleId, env), toNodeHex)
        // Tell this peer about EVERY relay I know for the circle, so we pool all mailboxes.
        for (nodeHex in relaysFor(circleId)) {
            val sealed = runCatching { social.sealCircleMedia(circleId, nodeHex.toByteArray()) }.getOrNull()
            if (sealed != null) sendFrame(Wire.RELAY_NODE, Wire.eventPayload(circleId, sealed), toNodeHex)
        }
    }

    /** Periodic/triggered sync: greet every contact so circles form + back-fill. */
    fun syncWithContacts() {
        if (!ready) return
        val snapshot = contacts.map { it.idHex }
        for (idHex in snapshot) sendHello(DEFAULT_CIRCLE, idHex)
    }

    private fun helloPayload(circleId: String): ByteArray? {
        val name = profile.displayName.ifBlank { "Someone" }
        val circleName = social.circles().firstOrNull { it.id == circleId }?.name ?: "My Circle"
        val bundle = social.myBundle()
        val signed = social.mySignedProfile(name, profile.bio, profile.link, profile.avatarB64, profile.emoji)
        return Wire.helloPayload(circleId, circleName, bundle, signed)
    }

    /** Author a post in a circle and broadcast the sealed event to its members. */
    fun post(circleId: String, body: String, media: List<String> = emptyList(),
             music: uniffi.haven_ffi.TrackRefFfi? = null) {
        if (body.isBlank() && media.isEmpty() && music == null) return
        val env = runCatching {
            social.post(circleId, body, media, music, null, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
        scope.launch { media.forEach { uploadMedia(circleId, it) } }   // push photos/videos to the relay
        // "Save my posts to Photos" (iOS parity).
        if (media.isNotEmpty() && ProfileStore.get(appContext).saveMyPosts)
            scope.launch { media.forEach { MediaSaver.autoSave(appContext, it) } }
    }

    /** Build a portable track reference from a shared streaming link (YouTube/Spotify/etc.). */
    fun trackFromLink(url: String, title: String, artist: String): uniffi.haven_ffi.TrackRefFfi =
        uniffi.haven_ffi.TrackRefFfi(
            catalogId = url, title = title.ifBlank { "Shared track" },
            artist = artist, artworkUrl = "", durationMs = 0UL,
        )

    /** Post a story (a post with the story flag + 24h retention; auto-expires). */
    fun postStory(body: String, mediaId: String?, music: uniffi.haven_ffi.TrackRefFfi? = null) {
        if (body.isBlank() && mediaId == null && music == null) return
        val env = runCatching {
            social.post(DEFAULT_CIRCLE, body, listOfNotNull(mediaId), music, 86_400UL, true, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(DEFAULT_CIRCLE, env)
        scope.launch { mediaId?.let { uploadMedia(DEFAULT_CIRCLE, it) } }
    }

    /** React / unreact / comment on a post — author + broadcast, same as a post. */
    fun react(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.react(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    fun unreact(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.unreact(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    fun comment(circleId: String, postId: String, body: String) {
        if (body.isBlank()) return
        val env = runCatching { social.comment(circleId, postId, body, emptyList(), nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Edit your own post's text; broadcasts the edit event. */
    fun editPost(circleId: String, postId: String, body: String) {
        val env = runCatching {
            social.edit(circleId, postId, body, emptyList(), null, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Unsend (delete) your own post; broadcasts the unsend event. */
    fun unsendPost(circleId: String, postId: String) {
        val env = runCatching { social.unsend(circleId, postId, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Persist, bump the feed, and broadcast a freshly-authored sealed envelope to members. */
    private fun afterAuthor(circleId: String, env: ByteArray) {
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
        val payload = Wire.eventPayload(circleId, env)
        for (idHex in social.contactNodeIds(circleId)) sendFrame(Wire.EVENT, payload, idHex)
        // Store-and-forward via the circle relay so offline members still get it.
        scope.launch { uploadEvent(circleId, env) }
        // Nearby mesh (never DMs — they stay point-to-point, matching iOS).
        if (NearbyTransport.active && !circleId.startsWith("dm:")) {
            NearbyTransport.broadcast(Wire.frame(Wire.EVENT, payload))
        }
    }

    // ---- Nearby offline mesh (opt-in) ----

    private fun nearbyPrefs() = appContext.getSharedPreferences("haven.nearby", Context.MODE_PRIVATE)
    fun enableNearby() { nearbyPrefs().edit().putBoolean("on", true).apply(); NearbyTransport.start(appContext) }
    fun disableNearby() { nearbyPrefs().edit().putBoolean("on", false).apply(); NearbyTransport.stop() }
    fun nearbyActive(): Boolean = NearbyTransport.active
    /** The user's persisted intent — default ON for a P2P app. */
    fun nearbyWanted(): Boolean = nearbyPrefs().getBoolean("on", true)
    /** On launch: auto-start Nearby if wanted (default) and the perms are already granted. */
    fun restoreNearbyIfWanted() {
        if (nearbyWanted() && NearbyTransport.hasPermissions(appContext)) runCatching { NearbyTransport.start(appContext) }
    }

    /** A nearby peer just connected — greet over the mesh + back-fill the open circle. */
    fun onNearbyConnected() {
        val hello = helloPayload(DEFAULT_CIRCLE) ?: return
        NearbyTransport.broadcast(Wire.frame(Wire.HELLO, hello))
        for (env in runCatching { social.syncEnvelopes(DEFAULT_CIRCLE) }.getOrDefault(emptyList())) {
            NearbyTransport.broadcast(Wire.frame(Wire.EVENT, Wire.eventPayload(DEFAULT_CIRCLE, env)))
        }
    }

    // ---- Circle relay / mailbox (store-and-forward, so posts cross even when not both online) ----

    /** Frame 19: [LP circleId][sealCircleMedia(relay node hex)]. Store the relay + backfill/poll. */
    private fun handleRelayNode(body: ByteArray) {
        val r = Wire.Reader(body)
        val cidBytes = r.lp() ?: return
        val circleId = String(cidBytes, Charsets.UTF_8)
        val sealed = r.rest()
        if (circleId.isEmpty() || sealed.isEmpty()) return
        val open = runCatching { social.openCircleMedia(circleId, sealed) }.getOrNull() ?: return
        val nodeHex = String(open, Charsets.UTF_8).trim()
        if (nodeHex.length != 64) return
        // A contact advertised their circle relay → ADD it to our redundant set for this circle,
        // so members automatically pool relays (more redundancy, no manual setup). Append, never
        // replace — parity with desktop handle_relay_node.
        val list = relayNodes.getOrPut(circleId) { mutableListOf() }
        if (list.contains(nodeHex)) return
        list.add(nodeHex)
        saveRelayNodes()
        Log.i(TAG, "learned relay for $circleId: ${nodeHex.take(8)}")
        scope.launch {
            backfillMailbox(circleId)   // upload everything I've already posted here
            pollMailbox()
        }
    }

    /** Frame 20: [LP circleId][sealCircleMedia(bootstrap GET URL)] for the S3 pre-signed pool. */
    private fun handlePresignBootstrap(body: ByteArray) {
        val r = Wire.Reader(body)
        val cidBytes = r.lp() ?: return
        val circleId = String(cidBytes, Charsets.UTF_8)
        val sealed = r.rest()
        if (circleId.isEmpty() || sealed.isEmpty()) return
        val open = runCatching { social.openCircleMedia(circleId, sealed) }.getOrNull() ?: return
        val url = String(open, Charsets.UTF_8).trim()
        if (!url.startsWith("http")) return
        Presign.setBootstrap(circleId, url)
        Log.i(TAG, "adopted S3 presign pool for $circleId")
        scope.launch { backfillMailbox(circleId); pollMailbox() }
    }

    /**
     * Adopt a relay node for all circles (Settings paste) — ADDED to the redundant set, not
     * replacing existing relays — + tell contacts via frame 19. Adopt several for redundancy.
     */
    fun adoptRelay(nodeHex: String) {
        val hex = nodeHex.trim().lowercase()
        if (hex.length != 64) return
        scope.launch {
            for (c in social.circles()) {
                val cid = c.id
                val list = relayNodes.getOrPut(cid) { mutableListOf() }
                if (!list.contains(hex)) list.add(hex)
                // Tell members (sealed) so they use the same mailbox.
                val sealed = runCatching { social.sealCircleMedia(cid, hex.toByteArray()) }.getOrNull()
                if (sealed != null) {
                    val frame = Wire.eventPayload(cid, sealed)  // [LP cid][sealed] — same layout as frame 19
                    for (idHex in social.contactNodeIds(cid)) sendFrame(Wire.RELAY_NODE, frame, idHex)
                }
                backfillMailbox(cid)
            }
            saveRelayNodes()
            withContext(Dispatchers.Main) { bumpRelays() }
            pollMailbox()
        }
    }

    /** Drop a relay from every circle (and forget its cached connection + health). */
    fun forgetRelay(nodeHex: String) {
        val hex = nodeHex.trim().lowercase()
        scope.launch {
            for (list in relayNodes.values) list.removeAll { it == hex }
            relayNodes.entries.removeAll { it.value.isEmpty() }
            saveRelayNodes()
            relayMutex.withLock {
                runCatching { relayClients.remove(hex)?.close() }
                relayHealth.remove(hex)
            }
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Bump so the relay-settings UI recomposes after the adopted set / health changes. */
    var relaysVersion = mutableStateOf(0); private set
    private fun bumpRelays() { relaysVersion.value++ }

    /** The redundant relay set for a circle (mirrored writes, fallback reads). */
    private fun relaysFor(circleId: String): List<String> = relayNodes[circleId]?.toList() ?: emptyList()

    /** Every distinct adopted relay across all circles. */
    private fun allRelays(): List<String> = relayNodes.values.flatten().distinct()

    private fun relayAvailable(nodeHex: String): Boolean =
        relayHealth[nodeHex]?.available(System.currentTimeMillis()) ?: true

    private fun markRelayOk(nodeHex: String) {
        relayHealth.getOrPut(nodeHex) { RelayHealth() }.recordSuccess()
    }

    private fun markRelayFail(nodeHex: String) {
        relayHealth.getOrPut(nodeHex) { RelayHealth() }.recordFailure(System.currentTimeMillis())
    }

    /** (nodeHex, reachable, isHostedByUs) for every distinct adopted relay — for the UI. */
    fun relaysDetail(): List<Triple<String, Boolean, Boolean>> {
        val hosted = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        return allRelays().map { hex ->
            Triple(hex, relayAvailable(hex), hosted == hex)
        }
    }

    // ---- Hosting: run the circle's relay in-process on this device ----

    private var relayHost: uniffi.haven_ffi.RelayServerHandle? = null
    val hosting = mutableStateOf(false)

    /** Start serving the circle's mailbox from this device + adopt it for every circle. */
    fun startHosting() {
        if (relayHost != null) return
        scope.launch {
            // A stable relay-specific seed, distinct from the messaging identity (per the core's contract).
            val relaySeed = MessageDigest.getInstance("SHA-256")
                .digest(core.seed + "haven-relay".toByteArray())
            val dir = File(appContext.filesDir, "relay").apply { mkdirs() }.absolutePath
            val h = runCatching { uniffi.haven_ffi.RelayServerHandle.start(relaySeed, dir) }
                .getOrElse { Log.e(TAG, "relay host start failed", it); return@launch }
            relayHost = h
            withContext(Dispatchers.Main) { hosting.value = true }
            val nodeHex = h.nodeIdHex()
            Log.i(TAG, "hosting circle relay: ${nodeHex.take(8)}")
            adoptRelay(nodeHex)   // use it + tell contacts via frame 19
        }
    }

    fun stopHosting() {
        runCatching { relayHost?.close() }
        relayHost = null
        hosting.value = false
    }

    /**
     * Mesh anti-entropy: if we host an in-app relay, pull every sealed blob each adopted SIBLING
     * relay holds that we lack, so the mailbox self-replicates across relays — any relay can then
     * join/leave freely without losing the circle's data. Parity with desktop engine.mesh_sync.
     *
     * Calls the core's `RelayServerHandle::sync_from(peerNodeHex) -> u32` FFI per sibling. The
     * generated uniffi bindings (haven_ffi.kt) currently PREDATE sync_from (they only expose
     * nodeIdHex), so we invoke it reflectively: this compiles + runs against the current .so once
     * the bindings are regenerated (android/build-rust.sh), and no-ops harmlessly until then.
     */
    private suspend fun meshSync() {
        val host = relayHost ?: return
        val myHex = runCatching { host.nodeIdHex() }.getOrNull() ?: return
        val syncFrom = runCatching {
            host.javaClass.methods.firstOrNull {
                it.name == "syncFrom" && it.parameterTypes.size == 1 &&
                    it.parameterTypes[0] == String::class.java
            }
        }.getOrNull() ?: return   // bindings predate sync_from — skip until regenerated
        for (peer in allRelays()) {
            if (peer == myHex || !relayAvailable(peer)) continue
            val pulled = runCatching {
                // sync_from is `async fn` → uniffi generates a `suspend` method, surfaced over JNA
                // as a method returning a value (the bindings drive the future). Reflective call.
                when (val r = syncFrom.invoke(host, peer)) {
                    is Number -> r.toLong()
                    else -> 0L
                }
            }.getOrDefault(0L)
            if (pulled > 0L) {
                markRelayOk(peer)
                withContext(Dispatchers.Main) { relayActive.value = true }
            }
        }
    }

    private suspend fun relayClientFor(nodeHex: String): RelayClient? = relayMutex.withLock {
        relayClients[nodeHex]?.let { return it }
        // Skip a relay that's in its backoff window — try the others instead.
        if (!relayAvailable(nodeHex)) return null
        val c = runCatching { RelayClient.connect(core.seed, nodeHex) }.getOrNull()
        if (c == null) { markRelayFail(nodeHex); return null }
        markRelayOk(nodeHex)
        relayClients[nodeHex] = c
        c
    }

    /** On a put/list/get failure: back the relay off and drop its cached connection. */
    private suspend fun relayFailed(nodeHex: String) = relayMutex.withLock {
        markRelayFail(nodeHex)
        runCatching { relayClients.remove(nodeHex)?.close() }
        Unit
    }

    private fun mailboxKey(circleId: String, env: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").digest(env).joinToString("") { "%02x".format(it) }
        return "haven/mailbox/$circleId/$h"
    }

    /** Drop a sealed event into the circle's mailbox (Haven relay node and/or S3 pre-signed pool). */
    private suspend fun uploadEvent(circleId: String, env: ByteArray) {
        // S3 pre-signed pool (the BYO-bucket path many circles use).
        if (Presign.hasBootstrap(circleId)) {
            if (Presign.uploadEvent(circleId, nodeIdHex, env)) {
                withContext(Dispatchers.Main) { relayActive.value = true }
            }
        }
        // Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        // re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        val key = mailboxKey(circleId, env)
        for (nodeHex in relaysFor(circleId)) {
            val client = relayClientFor(nodeHex) ?: continue
            runCatching { client.put(key, env) }
                .onSuccess {
                    markRelayOk(nodeHex)
                    withContext(Dispatchers.Main) { relayActive.value = true }
                }
                .onFailure { Log.d(TAG, "mailbox put failed ($nodeHex): ${it.message}"); relayFailed(nodeHex) }
        }
    }

    /** Re-upload every post I authored in a circle (for members who were offline when I posted). */
    private suspend fun backfillMailbox(circleId: String) {
        if (relaysFor(circleId).isEmpty() && !Presign.hasBootstrap(circleId)) return
        val envs = runCatching { social.exportMyEnvelopes(circleId) }.getOrDefault(emptyList())
        for (env in envs) uploadEvent(circleId, env)
        // Also push the media bytes of anything I've posted here that I still hold locally.
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        for (item in feed) if (item.isMe) item.media.forEach { if (LocalMedia.has(it)) uploadMedia(circleId, it) }
    }

    /** Poll every circle's mailbox; ingest envelopes we haven't seen. */
    suspend fun pollMailbox() {
        if (!ready) return
        var changed = false
        // S3 pre-signed pools (the BYO-bucket path).
        for (circleId in Presign.circles()) {
            val items = runCatching { Presign.poll(circleId, seenMailbox) }.getOrDefault(emptyList())
            if (items.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            for ((key, env) in items) {
                seenMailbox.add(key)
                if (runCatching { social.receive(circleId, env) }.getOrDefault(false)) {
                    changed = true; notifyInbound(circleId)
                }
            }
        }
        // (circleId, relayNodeHex) for every circle × every configured relay — reading from all of
        // them means a message present on ANY reachable relay still arrives. seenMailbox is keyed
        // by the content-addressed key, so the same envelope mirrored on several relays is
        // ingested exactly once (dedup by content key).
        val relayTargets: List<Pair<String, String>> = relayNodes.toMap()
            .flatMap { (cid, list) -> list.map { cid to it } }
        for ((circleId, nodeHex) in relayTargets) {
            val client = relayClientFor(nodeHex) ?: continue
            val prefix = "haven/mailbox/$circleId/"
            val keys = runCatching { client.list(prefix) }.getOrNull()
            if (keys == null) { relayFailed(nodeHex); continue }
            markRelayOk(nodeHex)
            if (keys.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            for (key in keys) {
                if (seenMailbox.contains(key)) continue
                val env = runCatching { client.get(key) }.getOrNull() ?: continue
                seenMailbox.add(key)
                if (runCatching { social.receive(circleId, env) }.getOrDefault(false)) {
                    changed = true
                    notifyInbound(circleId)
                }
            }
        }
        // Mesh: if we host a relay, pull from each adopted sibling so the mailbox self-replicates.
        meshSync()
        if (changed) {
            persist()
            withContext(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()
        }
    }

    // ---- Cross-device media bytes (frame 3 request / frame 5 sealed chunks), like iOS ----

    private val mediaChunkSize = 512 * 1024
    private class IncomingMedia(val total: Int) { val chunks = HashMap<Int, ByteArray>() }
    private val incomingMedia = HashMap<String, IncomingMedia>()
    private val requestedRefs = HashSet<String>()

    private fun mediaKey(ref: String) = "haven/media/$ref"

    /** Fetch missing feed media: try the circle relay (haven/media/<ref>) first, then ask contacts. */
    fun requestMissingMedia() {
        if (!ready) return
        val myHex = nodeIdHex
        val missing = LinkedHashMap<String, String>()   // ref -> circleId
        for (c in social.circles()) {
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) {
                item.media.forEach { if (!LocalMedia.has(it)) missing.putIfAbsent(it, c.id) }
                item.comments.forEach { cm -> cm.media.forEach { if (!LocalMedia.has(it)) missing.putIfAbsent(it, c.id) } }
            }
        }
        for ((ref, circleId) in missing) {
            scope.launch {
                if (fetchMediaFromRelay(circleId, ref)) {
                    withContext(Dispatchers.Main) { feedVersion.value++ }
                    return@launch
                }
                if (!requestedRefs.add(ref)) return@launch   // ask peers once per session per ref
                val payload = myHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
                for (idHex in contacts.map { it.idHex }) sendFrame(Wire.MEDIA_REQ, payload, idHex)
            }
        }
    }

    /** Mirror a sealed media blob to EVERY circle relay (redundancy) so members can fetch offline. */
    suspend fun uploadMedia(circleId: String, ref: String) {
        val blob = LocalMedia.rawSealed(ref) ?: return
        val key = mediaKey(ref)
        for (nodeHex in relaysFor(circleId)) {
            val client = relayClientFor(nodeHex) ?: continue
            runCatching { client.put(key, blob) }
                .onSuccess { markRelayOk(nodeHex) }
                .onFailure { relayFailed(nodeHex) }
        }
    }

    private suspend fun fetchMediaFromRelay(circleId: String, ref: String): Boolean {
        val key = mediaKey(ref)
        // Try each relay in turn; the first that has the blob wins (graceful fallback).
        for (nodeHex in relaysFor(circleId)) {
            val client = relayClientFor(nodeHex) ?: continue
            val blob = runCatching { client.get(key) }.getOrNull()
            if (blob == null) { relayFailed(nodeHex); continue }
            markRelayOk(nodeHex)
            LocalMedia.writeRawSealed(ref, blob)
            return true
        }
        return false
    }

    /** Frame 3: [hex64 requester][ref]. If we hold the bytes, stream them back as sealed chunks. */
    private fun handleMediaRequest(body: ByteArray) {
        if (body.size <= 64) return
        val requester = String(body.copyOfRange(0, 64), Charsets.UTF_8)
        if (requester.length != 64) return
        val ref = String(body.copyOfRange(64, body.size), Charsets.UTF_8)
        if (ref.isEmpty() || !LocalMedia.has(ref)) return
        val bytes = LocalMedia.loadAnyCircle(ref) ?: return
        scope.launch { sendMediaChunks(ref, bytes, requester) }
    }

    private suspend fun sendMediaChunks(ref: String, bytes: ByteArray, requesterHex: String) {
        val total = maxOf(1, (bytes.size + mediaChunkSize - 1) / mediaChunkSize)
        val refBytes = ref.toByteArray(Charsets.UTF_8)
        var index = 0
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + mediaChunkSize, bytes.size)
            val chunk = bytes.copyOfRange(offset, end)
            val sealed = runCatching { social.sealMedia(requesterHex, chunk) }.getOrNull() ?: return
            sendFrame(Wire.MEDIA_CHUNK, chunkFrame(refBytes, index, total, sealed), requesterHex)
            offset = end; index++
        }
    }

    private fun chunkFrame(refBytes: ByteArray, index: Int, total: Int, sealed: ByteArray): ByteArray {
        val out = ArrayList<Byte>(2 + refBytes.size + 8 + sealed.size)
        out.add((refBytes.size and 0xFF).toByte()); out.add(((refBytes.size ushr 8) and 0xFF).toByte())
        refBytes.forEach { out.add(it) }
        for (v in intArrayOf(index, total)) {
            out.add((v and 0xFF).toByte()); out.add(((v ushr 8) and 0xFF).toByte())
            out.add(((v ushr 16) and 0xFF).toByte()); out.add(((v ushr 24) and 0xFF).toByte())
        }
        sealed.forEach { out.add(it) }
        return out.toByteArray()
    }

    /** Frame 5: reassemble sealed chunks; store the media when complete. */
    private fun handleMediaChunk(body: ByteArray) {
        if (body.size < 2) return
        val refLen = (body[0].toInt() and 0xFF) or ((body[1].toInt() and 0xFF) shl 8)
        if (body.size < 2 + refLen + 8) return
        val ref = String(body.copyOfRange(2, 2 + refLen), Charsets.UTF_8)
        var off = 2 + refLen
        fun u32(): Int {
            val v = (body[off].toInt() and 0xFF) or ((body[off + 1].toInt() and 0xFF) shl 8) or
                ((body[off + 2].toInt() and 0xFF) shl 16) or ((body[off + 3].toInt() and 0xFF) shl 24)
            off += 4; return v
        }
        val index = u32(); val total = u32()
        val sealed = body.copyOfRange(off, body.size)
        if (ref.isEmpty() || total <= 0 || LocalMedia.has(ref)) return
        val plain = runCatching { social.openMedia(sealed) }.getOrNull() ?: return
        val entry = incomingMedia.getOrPut(ref) { IncomingMedia(total) }
        entry.chunks[index] = plain
        if (entry.chunks.size >= entry.total) {
            val full = ByteArray(entry.chunks.values.sumOf { it.size })
            var p = 0
            for (i in 0 until entry.total) { val c = entry.chunks[i] ?: continue; c.copyInto(full, p); p += c.size }
            LocalMedia.storeUnderRef(DEFAULT_CIRCLE, ref, full.copyOf(p))
            incomingMedia.remove(ref)
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
            // "Save others' posts to Photos" (iOS parity) — auto-save received media once.
            if (ProfileStore.get(appContext).saveOthersPosts) scope.launch { MediaSaver.autoSave(appContext, ref) }
        }
    }

    private fun sendFrame(type: Int, payload: ByteArray, toNodeHex: String) {
        val n = node ?: return
        val frame = Wire.frame(type, payload)
        scope.launch {
            runCatching { n.sendToNode(toNodeHex, frame) }
                .onFailure { Log.d(TAG, "send type=$type to ${toNodeHex.take(8)} failed: ${it.message}") }
        }
    }

    // ---- Persistence ---------------------------------------------------------------------

    private fun persist() {
        runCatching { stateFile.writeBytes(social.exportState()) }
            .onFailure { Log.e(TAG, "persist failed", it) }
    }

    private fun restoreState() {
        if (stateFile.exists()) {
            runCatching { social.importState(stateFile.readBytes()) }
                .onFailure { Log.e(TAG, "restore failed", it) }
        }
    }

    private fun loadContacts() {
        val raw = prefs.getString("contacts", null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            contacts.clear()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                contacts.add(Contact(o.getString("id"), o.getString("name"), o.optString("v", "")))
            }
        }
    }

    private fun saveContacts() {
        val arr = JSONArray()
        contacts.forEach { arr.put(JSONObject().put("id", it.idHex).put("name", it.name).put("v", it.verifyHex)) }
        prefs.edit().putString("contacts", arr.toString()).apply()
    }

    private fun loadBlocked() {
        val raw = prefs.getString("blocked", null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            blocked.clear()
            for (i in 0 until arr.length()) blocked.add(arr.getString(i))
        }
    }

    private fun saveBlocked() {
        val arr = JSONArray()
        blocked.forEach { arr.put(it) }
        prefs.edit().putString("blocked", arr.toString()).apply()
    }

    /**
     * Load the redundant relay set. New format is `relays` (circleId -> JSON array of node hexes).
     * The legacy `relayNodes` (circleId -> single node hex string) is migrated in idempotently:
     * each legacy entry is appended to the list if not already present. The migration re-runs
     * harmlessly on every load until the next [saveRelayNodes] clears the legacy key.
     */
    private fun loadRelayNodes() {
        relayNodes.clear()
        // New multi-relay format.
        prefs.getString("relays", null)?.let { raw ->
            runCatching {
                val o = JSONObject(raw)
                o.keys().forEach { cid ->
                    val arr = o.getJSONArray(cid)
                    val list = mutableListOf<String>()
                    for (i in 0 until arr.length()) {
                        val hex = arr.getString(i)
                        if (hex.isNotEmpty() && !list.contains(hex)) list.add(hex)
                    }
                    if (list.isNotEmpty()) relayNodes[cid] = list
                }
            }
        }
        // Idempotent migration of the legacy single-relay-per-circle map.
        prefs.getString("relayNodes", null)?.let { raw ->
            runCatching {
                val o = JSONObject(raw)
                o.keys().forEach { cid ->
                    val hex = o.getString(cid)
                    if (hex.isNotEmpty()) {
                        val list = relayNodes.getOrPut(cid) { mutableListOf() }
                        if (!list.contains(hex)) list.add(hex)
                    }
                }
            }
        }
    }

    private fun saveRelayNodes() {
        val o = JSONObject()
        relayNodes.forEach { (k, v) -> o.put(k, JSONArray().apply { v.forEach { put(it) } }) }
        // Write the new format and clear the legacy key (completes the migration).
        prefs.edit().putString("relays", o.toString()).remove("relayNodes").apply()
    }

    /** Whether any circle has a mailbox configured — Haven relay node or S3 pool (UI indicator). */
    fun hasRelay(): Boolean = relayNodes.values.any { it.isNotEmpty() } || Presign.anyBootstrap()

    fun reset() {
        contacts.clear(); pending.clear(); blocked.clear(); initiated.clear()
        relayNodes.clear(); relayClients.clear(); relayHealth.clear(); seenMailbox.clear()
        Presign.reset()
        CircleLock.reset()
        AvatarStore.clear()
        relayActive.value = false
        activeCircle.value = DEFAULT_CIRCLE
        prefs.edit().clear().apply()
        runCatching { stateFile.delete() }
        feedVersion.value++
    }

    val engine: HavenSocial get() = social

    // ---- Demo seeding support (DEBUG-only; see DemoSeed.kt) ------------------------------
    //
    // These thin hooks let DemoSeed populate the same in-memory state the live handshake would,
    // without any networking. They are harmless in a real launch (only called when demo is on).

    /** True once [init] has run, so the seeder can drive the engine. */
    val isReady: Boolean get() = ready

    /** Register a synthetic contact (name + verified id) directly, as if a handshake completed. */
    fun demoAddContact(idHex: String, name: String, verifyHex: String) {
        if (idHex.isEmpty()) return
        if (contacts.none { it.idHex == idHex }) contacts.add(Contact(idHex, name, verifyHex))
    }

    /** Persist the engine state the seeder authored into (idempotent within a launch). */
    fun demoPersist() = persist()

    /** Present the seeded demo as a healthy, connected app for screenshots (no live node). */
    fun demoMarkConnected() {
        started.value = true
        internetActive.value = true
        relayActive.value = true
    }

    /** Recompose the feed/circle switcher after the seeder authored content. */
    fun demoRefresh() {
        bumpCircles()
        feedVersion.value++
    }
}

/** node-id hex = first 32 bytes of the bundle, lowercase hex (matches iOS nodeHex). */
fun nodeHex(bundle: ByteArray): String =
    bundle.take(32).joinToString("") { "%02x".format(it.toInt() and 0xFF) }

fun nowMs(): ULong = System.currentTimeMillis().toULong()
