package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import com.daasuu.mp4compose.FillMode
import com.daasuu.mp4compose.composer.Mp4Composer
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume

/**
 * Bakes a [FilterSpec] into a video by transcoding it (MediaCodec decode → our GLSL shader → encode)
 * with audio passed through. This is the Android equivalent of the iOS `AVMutableVideoComposition`
 * per-frame filter — same look, fully offline, no Google services.
 */
object VideoFilter {
    private const val TAG = "VideoFilter"

    /**
     * Transcode [src] applying [spec]; returns the filtered file, or [src] unchanged for Original /
     * on failure. [onProgress] reports 0…1. Suspends until the transcode finishes.
     */
    suspend fun transcode(context: Context, src: File, spec: FilterSpec, onProgress: (Double) -> Unit = {}): File {
        if (spec == FilterSpec() || !src.exists()) return src // Original — nothing to bake
        val dest = File(context.cacheDir, "filt_${src.nameWithoutExtension}_${spec.hashCode()}.mp4")
        if (dest.exists() && dest.length() > 0) return dest

        return suspendCancellableCoroutine { cont ->
            val composer = Mp4Composer(src.absolutePath, dest.absolutePath)
                .filter(HavenGlFilter(spec))
                .fillMode(FillMode.PRESERVE_ASPECT_FIT)
                .listener(object : Mp4Composer.Listener {
                    override fun onProgress(progress: Double) { onProgress(progress) }
                    override fun onCurrentWrittenVideoTime(timeUs: Long) {}
                    override fun onCompleted() {
                        if (cont.isActive) cont.resume(if (dest.exists() && dest.length() > 0) dest else src)
                    }
                    override fun onCanceled() { if (cont.isActive) cont.resume(src) }
                    override fun onFailed(exception: Exception) {
                        Log.e(TAG, "transcode failed", exception)
                        if (cont.isActive) cont.resume(src)
                    }
                })
            composer.start()
            cont.invokeOnCancellation { runCatching { composer.cancel() } }
        }
    }
}
