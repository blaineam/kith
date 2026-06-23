package com.blaineam.haven.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Holds text shared into Haven from another app (e.g. a YouTube or web link via the system share
 * sheet). The composer picks it up and prefills the draft, then clears it.
 */
object ShareInbox {
    var pending by mutableStateOf<String?>(null)
        private set

    fun offer(text: String?) {
        if (!text.isNullOrBlank()) pending = text.trim()
    }

    fun take(): String? {
        val t = pending
        pending = null
        return t
    }
}
