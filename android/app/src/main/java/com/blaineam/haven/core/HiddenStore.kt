package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf

/**
 * Posts the user has chosen to hide from their own feed. Purely local + per-device (it never touches
 * the circle/relay — hiding is a personal view preference, distinct from blocking or removing someone).
 * A "show hidden" toggle reveals them again so a hide is always reversible.
 */
object HiddenStore {
    /** Post ids the user has hidden. */
    val hidden = mutableStateListOf<String>()
    /** When true, hidden posts are shown (greyed/with an Unhide affordance) instead of filtered out. */
    val showHidden = mutableStateOf(false)

    private var prefs: android.content.SharedPreferences? = null
    private const val KEY = "ids"

    fun init(context: Context) {
        if (prefs != null) return
        prefs = context.applicationContext.getSharedPreferences("haven.hidden", Context.MODE_PRIVATE)
        hidden.clear()
        hidden.addAll(prefs?.getStringSet(KEY, emptySet()).orEmpty())
    }

    fun isHidden(id: String): Boolean = hidden.contains(id)

    fun hide(id: String) {
        if (!hidden.contains(id)) { hidden.add(id); save() }
    }

    fun unhide(id: String) {
        if (hidden.remove(id)) save()
    }

    fun toggleShowHidden() { showHidden.value = !showHidden.value }

    private fun save() {
        prefs?.edit()?.putStringSet(KEY, hidden.toSet())?.apply()
    }
}
