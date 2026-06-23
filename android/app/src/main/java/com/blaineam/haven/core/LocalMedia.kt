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

    /**
     * Store plaintext bytes sealed to [circleId]; returns a media ref. Videos are tagged "v:" so
     * the feed renders them as players (images stay bare for backward compatibility).
     */
    fun store(circleId: String, bytes: ByteArray, isVideo: Boolean = false): String {
        val hash = sha256Hex(bytes)
        val toWrite = runCatching { HavenNet.engine.sealCircleMedia(circleId, bytes) }.getOrNull() ?: bytes
        runCatching { File(dir, hash).writeBytes(toWrite) }
        return if (isVideo) "v:$hash" else hash
    }

    fun isVideo(ref: String): Boolean = ref.startsWith("v:")
    private fun bareId(ref: String): String = ref.removePrefix("v:").removePrefix("i:")

    /** Load + decrypt a stored media ref, or null if we don't have it. */
    fun load(circleId: String, ref: String): ByteArray? {
        val f = File(dir, bareId(ref))
        if (!f.exists()) return null
        val stored = f.readBytes()
        return runCatching { HavenNet.engine.openCircleMedia(circleId, stored) }.getOrNull() ?: stored
    }

    /** Decrypt a video ref to a cache file VideoView/MediaPlayer can read; null if missing. */
    fun videoFile(circleId: String, ref: String): File? {
        val bytes = load(circleId, ref) ?: return null
        val out = File(dir.parentFile, "vid_${bareId(ref)}.mp4")
        if (!out.exists()) runCatching { out.writeBytes(bytes) } else Unit
        return if (out.exists()) out else null
    }

    fun has(ref: String): Boolean = File(dir, bareId(ref)).exists()

    /** Load decrypted bytes trying each circle's key (for serving a media request). */
    fun loadAnyCircle(ref: String): ByteArray? {
        val f = File(dir, bareId(ref))
        if (!f.exists()) return null
        val stored = f.readBytes()
        for (c in HavenNet.engine.circles()) {
            runCatching { HavenNet.engine.openCircleMedia(c.id, stored) }.getOrNull()?.let { return it }
        }
        return stored   // fall back to raw (was stored unsealed)
    }

    /** Store received plaintext bytes under an exact ref (sealed at rest to the circle). */
    fun storeUnderRef(circleId: String, ref: String, bytes: ByteArray) {
        val toWrite = runCatching { HavenNet.engine.sealCircleMedia(circleId, bytes) }.getOrNull() ?: bytes
        runCatching { File(dir, bareId(ref)).writeBytes(toWrite) }
    }

    /** The at-rest sealed blob for a ref — uploaded to the relay verbatim (same form iOS stores). */
    fun rawSealed(ref: String): ByteArray? {
        val f = File(dir, bareId(ref))
        return if (f.exists()) f.readBytes() else null
    }

    /** Write a sealed blob fetched from the relay straight to disk (load() opens it on read). */
    fun writeRawSealed(ref: String, blob: ByteArray) {
        runCatching { File(dir, bareId(ref)).writeBytes(blob) }
    }

    /** Delete every stored media file (part of "start over"). */
    fun clear() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

/** Read a picked video's raw bytes, capped to avoid huge attachments (default 60 MB). */
fun readVideoBytes(context: Context, uri: Uri, maxBytes: Int = 60 * 1024 * 1024): ByteArray? =
    runCatching {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            if (bytes.size > maxBytes) null else bytes
        }
    }.getOrNull()

/** True if the picked uri is a video (by MIME type). */
fun isVideoUri(context: Context, uri: Uri): Boolean =
    context.contentResolver.getType(uri)?.startsWith("video") == true

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
