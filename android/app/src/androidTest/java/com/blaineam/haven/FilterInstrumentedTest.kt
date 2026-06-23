package com.blaineam.haven

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.GlPhotoFilter
import com.blaineam.haven.core.HavenFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/**
 * Proves the offscreen GL filter pipeline actually runs on the device and transforms pixels in the
 * directions the iOS FilterSpec implies — i.e. the SAME shader the video transcoder uses produces a
 * correct look. "unit-green ≠ device-working": this only passes if EGL + the generated GLSL compile
 * and execute on real hardware.
 */
@RunWith(AndroidJUnit4::class)
class FilterInstrumentedTest {

    private fun solid(c: Int, n: Int = 8): Bitmap =
        Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888).apply { eraseColor(c) }

    private fun center(b: Bitmap): Int = b.getPixel(b.width / 2, b.height / 2)

    @Test fun noir_makes_color_grayscale() {
        val out = center(GlPhotoFilter.apply(solid(Color.rgb(200, 60, 60)), HavenFilter.NOIR.spec))
        val r = Color.red(out); val g = Color.green(out); val b = Color.blue(out)
        // A toned B&W: the three channels collapse to near-equal (small warm/cool tint allowed).
        assertTrue("noir not desaturated: $r,$g,$b", abs(r - g) < 40 && abs(g - b) < 40)
    }

    @Test fun kodak_gold_warms_a_neutral_gray() {
        val src = Color.rgb(128, 128, 128)
        val out = center(GlPhotoFilter.apply(solid(src), HavenFilter.KODAK_GOLD.spec))
        // Warm film look: red should end up clearly above blue (was equal).
        assertTrue("kodak not warm: r=${Color.red(out)} b=${Color.blue(out)}", Color.red(out) > Color.blue(out) + 6)
    }

    @Test fun vivid_increases_saturation() {
        val src = Color.rgb(180, 110, 90)
        val before = src.let { maxOf(Color.red(it), Color.green(it), Color.blue(it)) - minOf(Color.red(it), Color.green(it), Color.blue(it)) }
        val out = center(GlPhotoFilter.apply(solid(src), HavenFilter.VIVID.spec))
        val after = maxOf(Color.red(out), Color.green(out), Color.blue(out)) - minOf(Color.red(out), Color.green(out), Color.blue(out))
        assertTrue("vivid did not boost saturation: $before -> $after", after >= before)
    }

    @Test fun original_is_passthrough() {
        val src = Color.rgb(123, 45, 67)
        val out = center(GlPhotoFilter.apply(solid(src), HavenFilter.ORIGINAL.spec))
        assertEquals(src, out)
    }
}
