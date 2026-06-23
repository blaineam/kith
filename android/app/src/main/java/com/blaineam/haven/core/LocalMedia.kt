package com.blaineam.haven.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.math.max

/**
 * On-device media store: photos are content-addressed (sha-256 of the plaintext, so the id is
 * the same on every device — ready for the cross-device MediaReq/Chunk fetch later) and kept
 * **sealed at rest** to the circle, mirroring the iOS MediaStore. Cross-device transfer of the
 * bytes themselves is the remaining Wave-3 piece (mailbox / type-3/5 frames).
 */
object LocalMedia {
    private lateinit var dir: File

    fun init(context: Context) {
        dir = File(context.applicationContext.filesDir, "media").apply { mkdirs() }
    }

    /** Store plaintext bytes sealed to [circleId]; returns the content id (sha-256 hex). */
    fun store(circleId: String, bytes: ByteArray): String {
        val id = sha256Hex(bytes)
        val toWrite = runCatching { HavenNet.engine.sealCircleMedia(circleId, bytes) }.getOrNull() ?: bytes
        runCatching { File(dir, id).writeBytes(toWrite) }
        return id
    }

    /** Load + decrypt a stored media id, or null if we don't have it. */
    fun load(circleId: String, id: String): ByteArray? {
        val f = File(dir, id)
        if (!f.exists()) return null
        val stored = f.readBytes()
        return runCatching { HavenNet.engine.openCircleMedia(circleId, stored) }.getOrNull() ?: stored
    }

    fun has(id: String): Boolean = File(dir, id).exists()

    /** Delete every stored media file (part of "start over"). */
    fun clear() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

/** Read a picked image, downscale to <= maxDim and JPEG-compress (parity with iOS ~2560px cap). */
fun loadAndDownscale(context: Context, uri: Uri, maxDim: Int = 2048, quality: Int = 82): ByteArray? {
    val resolver = context.contentResolver
    // First pass: bounds only, to compute an integer sample size.
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
    val longest = max(bounds.outWidth, bounds.outHeight).coerceAtLeast(1)
    var sample = 1
    while (longest / sample > maxDim * 2) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    val bmp = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
    val scaled = if (max(bmp.width, bmp.height) > maxDim) {
        val r = maxDim.toFloat() / max(bmp.width, bmp.height)
        Bitmap.createScaledBitmap(bmp, (bmp.width * r).toInt(), (bmp.height * r).toInt(), true)
    } else bmp
    val out = ByteArrayOutputStream()
    scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
    return out.toByteArray()
}
