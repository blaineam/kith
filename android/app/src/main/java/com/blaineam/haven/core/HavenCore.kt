package com.blaineam.haven.core

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.SelfTestReport
import uniffi.haven_ffi.selfTest

/**
 * The Android counterpart of the iOS AccountStore: owns the on-device identity (a 32-byte
 * master seed), persists it encrypted-at-rest in the Android Keystore, and hands out the
 * Rust [Account] object from the shared `haven_ffi` core.
 *
 * Mirrors the iOS keychain rule from memory: a *locked* read must never be confused with an
 * *absent* key, or we'd overwrite a real identity with a throwaway one. EncryptedSharedPreferences
 * does not have the pre-unlock window the iOS Keychain does, but we keep the same "only generate
 * when truly absent" contract.
 */
class HavenCore private constructor(
    private val prefs: SharedPreferences,
) {
    /** The live identity. Loaded from disk if present, otherwise freshly generated + saved. */
    val account: Account = loadOrCreate()

    val seed: ByteArray get() = account.secretSeed()
    val nodeIdHex: String get() = account.nodeIdHex()
    val verificationHex: String get() = account.verificationHex()

    /** A shareable invite link (haven:// URI). */
    fun inviteUri(): String = account.havenUri()

    /** Run the on-device privacy self-test (identity / seal-open / signing / link parsing). */
    fun runSelfTest(): SelfTestReport = selfTest()

    /** Wipe the identity and start over (parity with iOS "Start over"). */
    fun reset() {
        prefs.edit().remove(KEY_SEED).apply()
    }

    /** A QR/transfer payload carrying this identity's master seed (to adopt on another device). */
    fun exportSeedUri(): String = "haven-seed:" + Base64.encodeToString(seed, Base64.NO_WRAP)

    /** Adopt a seed scanned from another device. Returns true if it was a valid 32-byte seed. */
    fun importSeed(uri: String): Boolean {
        val b64 = uri.trim().removePrefix("haven-seed:")
        val s = runCatching { Base64.decode(b64, Base64.NO_WRAP) }.getOrNull() ?: return false
        if (s.size != 32) return false
        prefs.edit().putString(KEY_SEED, Base64.encodeToString(s, Base64.NO_WRAP)).apply()
        return true
    }

    private fun loadOrCreate(): Account {
        val stored = prefs.getString(KEY_SEED, null)
        if (stored != null) {
            val seed = Base64.decode(stored, Base64.NO_WRAP)
            return Account.fromSeed(seed)
        }
        val acct = Account.generate()
        prefs.edit()
            .putString(KEY_SEED, Base64.encodeToString(acct.secretSeed(), Base64.NO_WRAP))
            .apply()
        return acct
    }

    companion object {
        private const val PREFS_NAME = "haven.identity"
        private const val KEY_SEED = "master_seed_b64"

        @Volatile private var instance: HavenCore? = null

        fun get(context: Context): HavenCore =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(appContext: Context): HavenCore {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                appContext,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            return HavenCore(prefs)
        }
    }
}
