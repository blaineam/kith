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
        // Mint the SAME ref scheme as iOS (apple/HavenApp/Media.swift): the kind is encoded in the
        // prefix so a recipient on either platform knows how to render it. iOS hard-rejects any ref
        // without an img_/vid_/aud_ prefix, so bare hashes were being dropped cross-platform.
        return if (isVideo) "vid_$hash" else "img_$hash"
    }

    fun isVideo(ref: String): Boolean = ref.startsWith("vid_") || ref.startsWith("v:")
    fun isAudio(ref: String): Boolean = ref.startsWith("aud_")
    // Strip the kind prefix (ours or iOS's) to the on-disk storage key. Legacy v:/i: kept for
    // already-stored local media.
    private fun bareId(ref: String): String =
        ref.removePrefix("v:").removePrefix("i:")
            .removePrefix("img_").removePrefix("vid_").removePrefix("aud_")

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

/**
 * Read a picked image, fix its EXIF orientation, downscale to <= maxDim, and JPEG-compress.
 * Reads the URI's bytes ONCE (re-opening a picker content stream often fails → blank previews),
 * samples down to avoid OOM on large photos, and applies EXIF rotation (so photos aren't sideways).
 */
fun loadAndDownscale(
    context: Context, uri: Uri,
    maxDim: Int = if (ProfileStore.get(context).autoOptimize) 2048 else 4096,
    quality: Int = if (ProfileStore.get(context).autoOptimize) 82 else 95,
): ByteArray? = runCatching {
    val raw = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        ?: return null.also { android.util.Log.w("LocalMedia", "openInputStream null for $uri") }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
    val longest = max(bounds.outWidth, bounds.outHeight).coerceAtLeast(1)
    var sample = 1
    while (longest / sample > maxDim) sample *= 2   // sample DOWN to ~maxDim — avoids OOM

    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    var bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)
        ?: return null.also { android.util.Log.w("LocalMedia", "decode failed for $uri") }

    // Downscale the rest of the way if still over the cap.
    if (max(bmp.width, bmp.height) > maxDim) {
        val r = maxDim.toFloat() / max(bmp.width, bmp.height)
        bmp = Bitmap.createScaledBitmap(bmp, (bmp.width * r).coerceAtLeast(1f).toInt(), (bmp.height * r).coerceAtLeast(1f).toInt(), true)
    }
    // Apply EXIF orientation (gallery/camera photos are often rotated/mirrored in metadata).
    val rot = runCatching {
        val exif = androidx.exifinterface.media.ExifInterface(java.io.ByteArrayInputStream(raw))
        when (exif.getAttributeInt(androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
            androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL)) {
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
    }.getOrDefault(0f)
    if (rot != 0f) {
        val m = android.graphics.Matrix().apply { postRotate(rot) }
        bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
    }

    ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
}.getOrElse { android.util.Log.e("LocalMedia", "loadAndDownscale failed", it); null }
