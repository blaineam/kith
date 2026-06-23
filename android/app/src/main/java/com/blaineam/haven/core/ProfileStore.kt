package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Lightweight observable profile + onboarding state, the Android counterpart of the iOS
 * ProfileStore. Backed by plain SharedPreferences (non-secret display data); the identity
 * itself lives in [HavenCore] / the Keystore.
 */
class ProfileStore private constructor(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("haven.profile", Context.MODE_PRIVATE)

    var onboarded by mutableStateOf(prefs.getBoolean(KEY_ONBOARDED, false))
        private set
    var displayName by mutableStateOf(prefs.getString(KEY_NAME, "") ?: "")
    var bio by mutableStateOf(prefs.getString(KEY_BIO, "") ?: "")
    var emoji by mutableStateOf(prefs.getString(KEY_EMOJI, "🌅") ?: "🌅")

    /** Auto-expire posts older than this many days (0 = keep forever). Parity with iOS retention. */
    var retentionDays by mutableStateOf(prefs.getInt(KEY_RETENTION, 0))

    /** Retention as a seconds value for the engine's feed() call (null = keep forever). */
    fun retentionSecs(): ULong? = if (retentionDays <= 0) null else (retentionDays.toLong() * 86_400L).toULong()

    fun setRetention(days: Int) {
        retentionDays = days
        prefs.edit().putInt(KEY_RETENTION, days).apply()
    }

    fun completeOnboarding(name: String, emoji: String) {
        displayName = name
        this.emoji = emoji
        onboarded = true
        prefs.edit()
            .putString(KEY_NAME, name)
            .putString(KEY_EMOJI, emoji)
            .putBoolean(KEY_ONBOARDED, true)
            .apply()
    }

    fun save() {
        prefs.edit()
            .putString(KEY_NAME, displayName)
            .putString(KEY_BIO, bio)
            .putString(KEY_EMOJI, emoji)
            .apply()
    }

    fun reset() {
        onboarded = false
        displayName = ""
        bio = ""
        emoji = "🌅"
        prefs.edit().clear().apply()
    }

    companion object {
        private const val KEY_ONBOARDED = "onboarded"
        private const val KEY_NAME = "name"
        private const val KEY_BIO = "bio"
        private const val KEY_EMOJI = "emoji"
        private const val KEY_RETENTION = "retentionDays"

        @Volatile private var instance: ProfileStore? = null
        fun get(context: Context): ProfileStore =
            instance ?: synchronized(this) {
                instance ?: ProfileStore(context).also { instance = it }
            }
    }
}
