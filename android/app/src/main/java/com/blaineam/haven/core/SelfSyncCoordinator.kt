package com.blaineam.haven.core

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.AccountStateHandle
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.openAccountState
import uniffi.haven_ffi.sealAccountState
import uniffi.haven_ffi.selfSyncSlotKey
import uniffi.haven_ffi.selfSyncSlotPrefix
import java.io.File
import java.security.SecureRandom

/**
 * Multi-device live sync — the Android counterpart of apple/HavenApp/SelfSync.swift (roadmap D16).
 *
 * Makes a user's OWN devices converge: each device writes a self-encrypted snapshot of its account
 * state to a per-account mailbox slot it owns, and merges its peers' slots. The merge is the CRDT in
 * `p2pcore::selfsync` (last-write-wins per key), exposed through the FFI (`AccountStateHandle`,
 * `sealAccountState`/`openAccountState`, `selfSyncSlotKey`). The relay only ever holds ciphertext
 * sealed with a key only this account's devices can derive.
 *
 * Scope: PROFILE (name/emoji/bio/link), GLOBAL SETTINGS, CONTACTS, the BLOCKED LIST, and CIRCLES
 * (name + member bundles + relay nodes). Scalar keys (profile/setting) apply via [get]; set-like
 * state (contacts/blocked) reconciles via [entries], with local removals propagated as tombstones.
 *
 * Transport: RELAY-ONLY for now. Android's S3 path ([Presign]) is pre-signed-URL/circle-scoped, not
 * an arbitrary-key bucket, so it cannot host the `haven/<account>/selfsync/<device>` slot keys.
 * TODO: add a direct-bucket S3 self-sync path (own credentials) so sync works with no relay at all,
 * matching iOS's `SharedStore.ownerS3()` transport.
 *
 * The encodings of profile/setting/blocked/circle entries are byte-identical to iOS so the two
 * platforms converge on the same CRDT values (bool = 1 byte, retentionDays = Int32 LE, circle JSON
 * = sorted keys `{"members":[...],"name":"...","relays":[...]}` with base64 member bundles).
 */
object SelfSyncCoordinator {

    private const val TAG = "SelfSync"
    private const val PREFS = "haven.selfsync"
    private const val KEY_DEVICE_ID = "haven.selfsync.deviceId"

    /** Namespaces whose keys are dynamic (set-like) — used to detect LOCAL removals so they
     *  propagate as tombstones (unblock, delete contact). Scalar namespaces are never removed. */
    private val dynamicPrefixes = listOf("contact:", "blocked:")

    private lateinit var appContext: Context
    private val mutex = Mutex()          // coalesce concurrent syncs (iOS `inFlight`)
    @Volatile private var initialized = false

    fun init(context: Context) {
        if (initialized) return
        appContext = context.applicationContext
        initialized = true
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Last converged state, persisted so we can detect what changed locally (LWW only advances a
     *  key's stamp when its value actually changes — otherwise two devices would ping-pong). */
    private val baseFile: File get() = File(appContext.filesDir, "haven-selfsync.bin")

    /**
     * A stable **per-device** id. All of a user's devices share the account seed (same node id), so
     * each physical device needs its own id to own a sync slot and to break LWW ties. Random 32
     * bytes, generated once, stored device-local in SharedPreferences (hex), NEVER synced.
     */
    private val deviceId: ByteArray by lazy {
        val hex = prefs.getString(KEY_DEVICE_ID, null)
        val existing = hex?.let { fromHex(it) }
        if (existing != null && existing.size == 32) {
            existing
        } else {
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            prefs.edit().putString(KEY_DEVICE_ID, toHex(bytes)).apply()
            bytes
        }
    }

    private val deviceHex: String get() = toHex(deviceId)

    // MARK: state <-> CRDT mapping

    /**
     * The current local state as namespaced key -> value bytes (no stamps). [social] contributes
     * circle structure; without it, circles are simply not snapshotted.
     */
    private fun currentLocal(social: HavenSocial?): Map<String, ByteArray> {
        val m = LinkedHashMap<String, ByteArray>()
        val p = ProfileStore.get(appContext)
        m["profile:name"] = p.displayName.toByteArray(Charsets.UTF_8)
        m["profile:emoji"] = p.emoji.toByteArray(Charsets.UTF_8)
        m["profile:bio"] = p.bio.toByteArray(Charsets.UTF_8)
        m["profile:link"] = p.link.toByteArray(Charsets.UTF_8)
        // Settings live on ProfileStore on Android. Use iOS's exact key names where the concept
        // matches. (Android has no "silent" — skip it.)
        m["setting:saveToPhotos"] = byteArrayOf(if (p.saveMyPosts) 1 else 0)
        m["setting:saveOthersToPhotos"] = byteArrayOf(if (p.saveOthersPosts) 1 else 0)
        m["setting:autoOptimize"] = byteArrayOf(if (p.autoOptimize) 1 else 0)
        m["setting:retentionDays"] = int32LE(p.retentionDays)
        // Roster: contacts (full card) + blocked list.
        for (c in HavenNet.selfSyncContactsSnapshot()) {
            m["contact:${c.idHex}"] = encodeContact(c)
        }
        for (hex in HavenNet.selfSyncBlockedSnapshot()) {
            m["blocked:$hex"] = byteArrayOf(1)
        }
        // Circles: name + member bundles + relay nodes, so another device can reconstruct each
        // circle and seal to every member. (Additive in v1 — member/circle removal is a follow-up.)
        if (social != null) {
            for (ci in runCatching { social.circles() }.getOrDefault(emptyList())) {
                val members = runCatching { social.circleMemberBundles(ci.id) }.getOrDefault(emptyList())
                    .map { Base64.encodeToString(it, Base64.NO_WRAP) }.sorted()
                val relays = HavenNet.relaysForCircle(ci.id).sorted()
                m["circle:${ci.id}"] = encodeCircle(ci.name, members, relays)
            }
        }
        return m
    }

    /**
     * Write a merged state back into the local stores (only when a value actually differs, to avoid
     * feedback loops through the stores' observers).
     */
    private fun applyLocal(h: AccountStateHandle, social: HavenSocial?) {
        val p = ProfileStore.get(appContext)
        strValue(h, "profile:name")?.let { if (it != p.displayName) { p.displayName = it; p.save() } }
        strValue(h, "profile:emoji")?.let { if (it != p.emoji) { p.emoji = it; p.save() } }
        strValue(h, "profile:bio")?.let { if (it != p.bio) { p.bio = it; p.save() } }
        strValue(h, "profile:link")?.let { if (it != p.link) { p.link = it; p.save() } }

        boolValue(h, "setting:saveToPhotos")?.let { if (it != p.saveMyPosts) p.saveMyPosts = it }
        boolValue(h, "setting:saveOthersToPhotos")?.let { if (it != p.saveOthersPosts) p.saveOthersPosts = it }
        boolValue(h, "setting:autoOptimize")?.let { if (it != p.autoOptimize) p.autoOptimize = it }
        h.get("setting:retentionDays")?.let { v ->
            if (v.size == 4) {
                val n = int32LEValue(v)
                if (n != p.retentionDays) p.setRetention(n)
            }
        }

        // Roster reconciliation (set-like — enumerate the converged state via entries()).
        val live = h.entries()

        // Contacts: upsert everything present; drop locals the converged state no longer has
        // (a contact deleted on another device propagated as a tombstone).
        val wantContacts = HashMap<String, Contact>()
        for (e in live) if (e.key.startsWith("contact:")) {
            decodeContact(e.value)?.let { wantContacts[it.idHex] = it }
        }
        for (c in wantContacts.values) HavenNet.selfSyncUpsertContact(c)
        for (c in HavenNet.selfSyncContactsSnapshot()) {
            if (!wantContacts.containsKey(c.idHex)) HavenNet.selfSyncRemoveContact(c.idHex)
        }

        // Blocked list: reconcile both directions.
        val wantBlocked = HashSet<String>()
        for (e in live) if (e.key.startsWith("blocked:")) {
            wantBlocked.add(e.key.removePrefix("blocked:"))
        }
        val haveBlocked = HavenNet.selfSyncBlockedSnapshot().toHashSet()
        for (hex in wantBlocked - haveBlocked) HavenNet.selfSyncSetBlocked(hex, true)
        for (hex in haveBlocked - wantBlocked) HavenNet.selfSyncSetBlocked(hex, false)

        // Circles: reconstruct each synced circle — create it, register every member's bundle (so
        // this device can seal to them), and record its relay mailbox(es). Additive in v1.
        if (social != null) {
            val existing = runCatching { social.circles() }.getOrDefault(emptyList())
            for (e in live) if (e.key.startsWith("circle:")) {
                val id = e.key.removePrefix("circle:")
                val cs = decodeCircle(e.value) ?: continue
                runCatching { social.createCircle(id, cs.name) }   // no-op if it already exists
                val cur = existing.firstOrNull { it.id == id }
                if (cur != null && cur.name != cs.name) runCatching { social.renameCircle(id, cs.name) }
                for (b64 in cs.members) {
                    val bundle = runCatching { Base64.decode(b64, Base64.NO_WRAP) }.getOrNull() ?: continue
                    runCatching { social.addContactBundle(id, bundle) }
                }
                for (node in cs.relays) HavenNet.selfSyncAddRelay(id, node)
            }
        }
    }

    // MARK: sync

    /**
     * One full sync pass: fold local changes into the base with fresh stamps, merge every peer slot,
     * apply the converged result locally, persist, and re-publish our own slot. Safe to call on a
     * timer; coalesces if already running. No-op without an account or any relay. Returns true if the
     * merge brought in changes from another device (so the caller can refresh the UI).
     */
    suspend fun sync(social: HavenSocial?): Boolean {
        if (!initialized) return false
        if (mutex.isLocked) return false   // coalesce (iOS `inFlight`)
        return mutex.withLock { syncLocked(social) }
    }

    private suspend fun syncLocked(social: HavenSocial?): Boolean {
        val seed = HavenNet.accountSeed
        val accountHex = HavenNet.accountNodeHex
        if (accountHex.isEmpty()) return false
        val relays = HavenNet.selfSyncRelays()
        if (relays.isEmpty()) return false   // relay-only transport: nothing to sync over

        // 1. Base = last converged state (or empty).
        val base: AccountStateHandle = run {
            val data = runCatching { if (baseFile.exists()) baseFile.readBytes() else null }.getOrNull()
            if (data != null) runCatching { AccountStateHandle.fromBytes(data) }.getOrNull() ?: AccountStateHandle()
            else AccountStateHandle()
        }

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device).
        val now = System.currentTimeMillis().toULong()
        val local = currentLocal(social)
        for ((key, value) in local) {
            if (!value.contentEquals(base.get(key))) {
                runCatching { base.set(key, value, now, deviceId) }
            }
        }
        // Detect local removals in dynamic namespaces (a contact deleted, a peer unblocked) and
        // tombstone them so the removal propagates instead of a peer device re-adding them.
        for (e in base.entries()) {
            if (dynamicPrefixes.any { e.key.startsWith(it) } && !local.containsKey(e.key)) {
                runCatching { base.remove(e.key, now, deviceId) }
            }
        }

        // Snapshot post-fold so we can tell whether the merge below actually brought anything new.
        val preMerge = base.toBytes()

        // 3. Pull + merge every peer slot from every relay.
        val prefix = "haven/" + selfSyncSlotPrefix(accountHex)
        val ownKey = "haven/" + selfSyncSlotKey(accountHex, deviceHex)
        for (nodeHex in relays) {
            val client = HavenNet.selfSyncRelayClient(nodeHex) ?: continue
            val keys = runCatching { client.list(prefix) }.getOrNull()
            if (keys == null) { HavenNet.selfSyncRelayFailed(nodeHex); continue }
            HavenNet.selfSyncRelayOk(nodeHex)
            for (key in keys) {
                if (key == ownKey) continue
                val blob = runCatching { client.get(key) }.getOrNull() ?: continue
                val peer = runCatching { openAccountState(seed, blob) }.getOrNull() ?: continue
                base.merge(peer)
            }
        }

        val changed = !base.toBytes().contentEquals(preMerge)

        // 4. Apply the converged state locally + persist the new base.
        applyLocal(base, social)
        runCatching { baseFile.writeBytes(base.toBytes()) }
            .onFailure { Log.e(TAG, "persist base failed", it) }
        if (changed) HavenNet.selfSyncDidApply()

        // 5. Re-publish our own slot (sealed) to every relay for redundancy.
        val sealed = runCatching { sealAccountState(seed, base) }.getOrNull() ?: return changed
        for (nodeHex in relays) {
            val client = HavenNet.selfSyncRelayClient(nodeHex) ?: continue
            runCatching { client.put(ownKey, sealed) }
                .onSuccess { HavenNet.selfSyncRelayOk(nodeHex) }
                .onFailure { Log.d(TAG, "slot put failed ($nodeHex): ${it.message}"); HavenNet.selfSyncRelayFailed(nodeHex) }
        }
        return changed
    }

    // MARK: encodings (byte-identical to iOS)

    private data class CircleSync(val name: String, val members: List<String>, val relays: List<String>)

    /**
     * A circle's portable structure as deterministic JSON with SORTED keys, so equal state encodes
     * to identical bytes on both platforms. Matches Swift's `JSONEncoder(.sortedKeys)` output:
     * `{"members":[...],"name":"...","relays":[...]}` (alphabetical keys, no whitespace). Members
     * are base64 member bundles (sorted), relays are node hexes (sorted). Strings escaped per JSON.
     */
    private fun encodeCircle(name: String, members: List<String>, relays: List<String>): ByteArray {
        val sb = StringBuilder()
        sb.append("{\"members\":")
        sb.append(jsonStringArray(members))
        sb.append(",\"name\":")
        sb.append(JSONObject.quote(name))
        sb.append(",\"relays\":")
        sb.append(jsonStringArray(relays))
        sb.append("}")
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    private fun jsonStringArray(items: List<String>): String {
        val sb = StringBuilder("[")
        for ((i, s) in items.withIndex()) {
            if (i > 0) sb.append(",")
            sb.append(JSONObject.quote(s))
        }
        sb.append("]")
        return sb.toString()
    }

    private fun decodeCircle(bytes: ByteArray): CircleSync? = runCatching {
        val o = JSONObject(String(bytes, Charsets.UTF_8))
        val members = ArrayList<String>()
        o.optJSONArray("members")?.let { for (i in 0 until it.length()) members.add(it.getString(i)) }
        val relays = ArrayList<String>()
        o.optJSONArray("relays")?.let { for (i in 0 until it.length()) relays.add(it.getString(i)) }
        CircleSync(o.optString("name", ""), members, relays)
    }.getOrNull()

    /** Stable Android contact JSON. Need NOT match iOS (structs differ) — just stable on Android. */
    private fun encodeContact(c: Contact): ByteArray =
        JSONObject().apply {
            put("id_hex", c.idHex)
            put("name", c.name)
            put("verify", c.verifyHex)
        }.toString().toByteArray(Charsets.UTF_8)

    private fun decodeContact(bytes: ByteArray): Contact? = runCatching {
        val o = JSONObject(String(bytes, Charsets.UTF_8))
        Contact(o.getString("id_hex"), o.optString("name", ""), o.optString("verify", ""))
    }.getOrNull()

    private fun int32LE(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 24) and 0xFF).toByte(),
    )

    private fun int32LEValue(b: ByteArray): Int =
        (b[0].toInt() and 0xFF) or
            ((b[1].toInt() and 0xFF) shl 8) or
            ((b[2].toInt() and 0xFF) shl 16) or
            ((b[3].toInt() and 0xFF) shl 24)

    private fun boolValue(h: AccountStateHandle, key: String): Boolean? {
        val v = h.get(key) ?: return null
        if (v.isEmpty()) return null
        return v[0].toInt() == 1
    }

    private fun strValue(h: AccountStateHandle, key: String): String? =
        h.get(key)?.let { String(it, Charsets.UTF_8) }

    // MARK: hex helpers

    private fun toHex(b: ByteArray): String =
        b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun fromHex(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val byte = hex.substring(i, i + 2).toIntOrNull(16) ?: return null
            out[i / 2] = byte.toByte()
            i += 2
        }
        return out
    }
}
