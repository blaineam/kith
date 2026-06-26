package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Posts queued to send at a future time. Haven is serverless + P2P, so — exactly like iOS
 * (apple/HavenApp/ScheduledStore.swift) — a scheduled item lives on THIS device and is posted by the
 * app when the time arrives (checked on resume + the sync tick). It won't fire while the phone is fully
 * off, but catches up the moment Haven is next foregrounded.
 */
object ScheduledStore {
    data class Item(
        val id: String, val circleId: String, val body: String,
        val media: List<String>, val retentionSecs: ULong?, val sendAtMs: Long,
    )

    /** Observable so the composer can show a "N scheduled" affordance. */
    val items = mutableStateListOf<Item>()
    private var file: File? = null

    fun init(context: Context) {
        if (file != null) return
        file = File(context.filesDir, "scheduled.json")
        load()
        fireDue()
    }

    fun schedule(circleId: String, body: String, media: List<String>, retentionSecs: ULong?, sendAtMs: Long) {
        items.add(Item(UUID.randomUUID().toString(), circleId, body, media, retentionSecs, sendAtMs))
        save()
    }

    fun pending(circleId: String): List<Item> = items.filter { it.circleId == circleId }.sortedBy { it.sendAtMs }

    fun cancel(id: String) { items.removeAll { it.id == id }; save() }

    /** Post anything now due, in order; called on app resume + the sync tick. */
    fun fireDue() {
        val now = System.currentTimeMillis()
        val due = items.filter { it.sendAtMs <= now }.sortedBy { it.sendAtMs }
        if (due.isEmpty()) return
        due.forEach { runCatching { HavenNet.post(it.circleId, it.body, it.media, null, it.retentionSecs) } }
        items.removeAll(due)
        save()
    }

    private fun load() {
        val f = file ?: return
        if (!f.exists()) return
        runCatching {
            val arr = JSONArray(f.readText())
            items.clear()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val mediaArr = o.getJSONArray("media")
                val media = (0 until mediaArr.length()).map { mediaArr.getString(it) }
                val ret = if (o.isNull("retentionSecs")) null else o.getLong("retentionSecs").toULong()
                items.add(Item(o.getString("id"), o.getString("circleId"), o.getString("body"), media, ret, o.getLong("sendAtMs")))
            }
        }
    }

    private fun save() {
        val f = file ?: return
        runCatching {
            val arr = JSONArray()
            items.forEach { it ->
                arr.put(JSONObject().apply {
                    put("id", it.id); put("circleId", it.circleId); put("body", it.body)
                    put("media", JSONArray(it.media))
                    put("retentionSecs", it.retentionSecs?.toLong() ?: JSONObject.NULL)
                    put("sendAtMs", it.sendAtMs)
                })
            }
            f.writeText(arr.toString())
        }
    }
}
