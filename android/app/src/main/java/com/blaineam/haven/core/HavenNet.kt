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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.HavenNode
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.InboundListener
import uniffi.haven_ffi.parseLink
import java.io.File

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
    var internetActive = mutableStateOf(false); private set
    var started = mutableStateOf(false); private set
    var feedVersion = mutableStateOf(0); private set   // bump to recompose the feed

    // node ids we initiated a connect to (scanned their QR) → expected verify hash.
    private val initiated = HashMap<String, String>()

    private val stateFile: File get() = File(appContext.filesDir, "haven_social_state.bin")
    private val prefs get() = appContext.getSharedPreferences("haven.contacts", Context.MODE_PRIVATE)

    fun init(context: Context) {
        if (this::appContext.isInitialized) return
        appContext = context.applicationContext
        core = HavenCore.get(appContext)
        profile = ProfileStore.get(appContext)
        social = HavenSocial(core.seed)
        restoreState()
        loadContacts()
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
            } catch (e: Throwable) {
                Log.e(TAG, "node start failed", e)
            }
        }
    }

    val nodeIdHex: String get() = core.nodeIdHex
    fun inviteUri(): String = core.inviteUri()

    // ---- Inbound dispatch (called off-main by the Rust node) -----------------------------

    override fun onInbound(payload: ByteArray) {
        if (payload.isEmpty()) return
        val type = payload[0].toInt() and 0xFF
        val body = payload.copyOfRange(1, payload.size)
        scope.launch {
            withContext(Dispatchers.Main) { internetActive.value = true }
            when (type) {
                Wire.HELLO -> handleHello(body)
                Wire.EVENT -> handleEvent(body)
                else -> Log.d(TAG, "ignoring frame type $type (not yet handled)")
            }
        }
    }

    private fun handleHello(payload: ByteArray) {
        val hello = Wire.parseHello(payload) ?: return
        val idHex = nodeHex(hello.bundle)
        val actualVerify = runCatching { social.bundleVerificationHex(hello.bundle) }.getOrNull() ?: return
        val name = runCatching { social.verifyProfile(hello.bundle, hello.signedProfile) }.getOrNull() ?: "Someone"

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
    fun sendDm(circleId: String, body: String) {
        if (body.isBlank()) return
        val env = runCatching {
            social.post(circleId, body, emptyList(), null, null, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    private fun handleEvent(payload: ByteArray) {
        val ev = Wire.parseEvent(payload) ?: return
        val changed = runCatching { social.receive(ev.circleId, ev.envelope) }.getOrDefault(false)
        if (changed) {
            persist()
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
        }
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
    }

    /** Periodic/triggered sync: greet every contact so circles form + back-fill. */
    fun syncWithContacts() {
        val snapshot = contacts.map { it.idHex }
        for (idHex in snapshot) sendHello(DEFAULT_CIRCLE, idHex)
    }

    private fun helloPayload(circleId: String): ByteArray? {
        val name = profile.displayName.ifBlank { "Someone" }
        val circleName = social.circles().firstOrNull { it.id == circleId }?.name ?: "My Circle"
        val bundle = social.myBundle()
        val signed = social.mySignedProfile(name, profile.bio, "")
        return Wire.helloPayload(circleId, circleName, bundle, signed)
    }

    /** Author a post in a circle and broadcast the sealed event to its members. */
    fun post(circleId: String, body: String, media: List<String> = emptyList()) {
        if (body.isBlank() && media.isEmpty()) return
        val env = runCatching {
            social.post(circleId, body, media, null, null, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
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

    /** Persist, bump the feed, and broadcast a freshly-authored sealed envelope to members. */
    private fun afterAuthor(circleId: String, env: ByteArray) {
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
        val payload = Wire.eventPayload(circleId, env)
        for (idHex in social.contactNodeIds(circleId)) sendFrame(Wire.EVENT, payload, idHex)
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

    fun reset() {
        contacts.clear(); pending.clear(); initiated.clear()
        prefs.edit().clear().apply()
        runCatching { stateFile.delete() }
        feedVersion.value++
    }

    val engine: HavenSocial get() = social
}

/** node-id hex = first 32 bytes of the bundle, lowercase hex (matches iOS nodeHex). */
fun nodeHex(bundle: ByteArray): String =
    bundle.take(32).joinToString("") { "%02x".format(it.toInt() and 0xFF) }

fun nowMs(): ULong = System.currentTimeMillis().toULong()
