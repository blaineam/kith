package com.blaineam.haven.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.FilterSpec
import com.blaineam.haven.core.GlPhotoFilter
import com.blaineam.haven.core.HavenFilter
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.VideoFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

private val capColors = listOf(Color.White, Color.Black, Color(0xFFEC4899), Color(0xFFF59E0B),
    Color(0xFF38BDF8), Color(0xFF34D399), Color(0xFFEF4444), Color(0xFFA855F7))
private val fontFamilies = listOf(FontFamily.SansSerif, FontFamily.Serif, FontFamily.Monospace, FontFamily.Cursive)
private fun typefaceFor(i: Int): Typeface = when (i % 4) {
    1 -> Typeface.create(Typeface.SERIF, Typeface.BOLD)
    2 -> Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    3 -> Typeface.create("cursive", Typeface.BOLD)
    else -> Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
}

/** iOS-style caption looks. */
private enum class CapStyle(val label: String) { PLAIN("Plain"), SHADOW("Shadow"), GLOW("Glow"), NEON("Neon"), HIGHLIGHT("Mark") }

/** Black text on light colors, white on dark — so highlighted text is always legible. */
private fun contrastOn(c: Color): Color =
    if (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.6) Color.Black else Color.White

private data class LiveCap(val textColor: Color, val shadow: Shadow?, val bg: Color)
private fun liveCap(style: CapStyle, color: Color): LiveCap = when (style) {
    CapStyle.PLAIN -> LiveCap(color, Shadow(Color.Black.copy(alpha = 0.55f), Offset(0f, 2f), 8f), Color.Transparent)
    CapStyle.SHADOW -> LiveCap(color, Shadow(Color.Black.copy(alpha = 0.85f), Offset(4f, 4f), 2f), Color.Transparent)
    CapStyle.GLOW -> LiveCap(color, Shadow(color.copy(alpha = 0.95f), Offset(0f, 0f), 22f), Color.Transparent)
    CapStyle.NEON -> LiveCap(Color.White, Shadow(color, Offset(0f, 0f), 28f), Color.Transparent)
    CapStyle.HIGHLIGHT -> LiveCap(contrastOn(color), null, color)
}

/**
 * iOS-style story editor: the 11-filter set (incl. Kodak Gold) on photos AND videos, a styled caption
 * (color · plain/shadow/glow/neon/highlight · font · size · drag), and a clean control stack so nothing
 * overlaps. Photos preview through the real GLSL filter; video autoplays (no chrome) and the filter is
 * baked on share. Filter + styled caption are baked into the bytes so recipients see the exact look.
 */
@Composable
fun StoryEditor(ref: String, isVideo: Boolean, initialFilter: Int = 0, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var caption by remember { mutableStateOf("") }
    var music by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var pickSong by remember { mutableStateOf(false) }
    var capOffset by remember { mutableStateOf(Offset.Zero) }
    var colorIdx by remember { mutableStateOf(0) }
    var styleIdx by remember { mutableStateOf(0) }
    var fontIdx by remember { mutableStateOf(0) }
    var sizeSp by remember { mutableStateOf(30f) }
    var filterIdx by remember { mutableStateOf(initialFilter.coerceIn(0, HavenFilter.all.size - 1)) }
    var showColors by remember { mutableStateOf(false) }
    var boxSize by remember { mutableStateOf(IntSize.Zero) }
    var sharing by remember { mutableStateOf(false) }
    var shareLabel by remember { mutableStateOf("Share to story") }

    val filter = HavenFilter.all[filterIdx]
    val style = CapStyle.entries[styleIdx % CapStyle.entries.size]
    val capColor = capColors[colorIdx % capColors.size]
    val lc = liveCap(style, capColor)

    // Source bitmap (photos) for filter preview + baking.
    var srcBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(ref) {
        if (!isVideo) srcBmp = withContext(Dispatchers.IO) {
            LocalMedia.load(DEFAULT_CIRCLE, ref)?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
        }
    }
    // Live GL-filtered photo preview (recomputed when filter/source changes).
    var previewBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(srcBmp, filterIdx) {
        val s = srcBmp ?: return@LaunchedEffect
        previewBmp = if (filter == HavenFilter.ORIGINAL) s
        else withContext(Dispatchers.Default) { runCatching { GlPhotoFilter.apply(s, filter.spec) }.getOrDefault(s) }
    }

    if (pickSong) {
        MusicSearchSheet(onPick = { music = it; pickSong = false }, onDismiss = { pickSong = false })
        return
    }

    Box(Modifier.fillMaxSize().background(Color.Black).onSizeChanged { boxSize = it }) {
        // ── Media (photo + video both preview the live filter) ─────────────────────────────
        if (isVideo) EditorVideo(ref, filter.spec, Modifier.fillMaxSize())
        else previewBmp?.let { Image(it.asImageBitmap(), "Story", Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }

        // ── Caption (lifts above the keyboard via imePadding) ──────────────────────────────
        Box(Modifier.fillMaxSize().imePadding()) {
            Box(
                Modifier.align(Alignment.Center)
                    .offset { IntOffset(capOffset.x.toInt(), capOffset.y.toInt()) }
                    .pointerInput(Unit) { detectDragGestures { _, drag -> capOffset += drag } }
                    .padding(horizontal = 24.dp),
            ) {
                BasicTextField(
                    value = caption, onValueChange = { caption = it },
                    textStyle = TextStyle(color = lc.textColor, fontSize = sizeSp.sp, fontWeight = FontWeight.Bold,
                        fontFamily = fontFamilies[fontIdx % fontFamilies.size], textAlign = TextAlign.Center, shadow = lc.shadow),
                    cursorBrush = SolidColor(HavenTheme.pink),
                    modifier = Modifier.wrapContentWidth().background(lc.bg, RoundedCornerShape(8.dp))
                        .padding(horizontal = if (lc.bg == Color.Transparent) 0.dp else 12.dp, vertical = if (lc.bg == Color.Transparent) 0.dp else 5.dp),
                    decorationBox = { inner ->
                        if (caption.isEmpty()) Text("Tap to type", color = Color.White.copy(alpha = 0.65f), fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        inner()
                    },
                )
            }
        }

        // ── Top bar: close + caption controls ──────────────────────────────────────────────
        Row(Modifier.align(Alignment.TopStart).statusBarsPadding().fillMaxWidth().padding(10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            CtlButton({ onClose() }) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
            Spacer(Modifier.weight(1f))
            CtlButton({ showColors = !showColors }) {
                Box(Modifier.size(22.dp).clip(CircleShape).background(capColor).border(1.5.dp, Color.White, CircleShape))
            }
            Spacer(Modifier.size(8.dp))
            // Style cycle — the "Aa" is drawn in the current style as a live hint.
            CtlButton({ styleIdx++ }) {
                Text("Aa", color = if (style == CapStyle.HIGHLIGHT) capColor else lc.textColor, fontWeight = FontWeight.Bold,
                    fontSize = 15.sp)
            }
            Spacer(Modifier.size(8.dp))
            CtlButton({ fontIdx++ }) { Text("Ag", color = Color.White, fontWeight = FontWeight.Bold, fontFamily = fontFamilies[fontIdx % fontFamilies.size]) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp - 4f).coerceAtLeast(16f) }) { Text("A−", color = Color.White, fontSize = 13.sp) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp + 4f).coerceAtMost(60f) }) { Text("A+", color = Color.White, fontSize = 15.sp) }
        }

        // Color swatches + the current style name (toggled under the top bar).
        if (showColors) {
            Column(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 60.dp, end = 10.dp),
                horizontalAlignment = Alignment.End) {
                Row(Modifier.clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.55f)).padding(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    capColors.forEachIndexed { i, c ->
                        Box(Modifier.size(26.dp).clip(CircleShape).background(c)
                            .border(if (i == colorIdx) 2.5.dp else 1.dp, Color.White.copy(alpha = if (i == colorIdx) 1f else 0.3f), CircleShape)
                            .clickable { colorIdx = i })
                    }
                }
                Spacer(Modifier.size(6.dp))
                Text(style.label, color = Color.White, fontSize = 12.sp,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 10.dp, vertical = 4.dp))
            }
        }

        // ── Bottom control stack: filter strip ABOVE the action row (no overlap) ───────────
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            LazyRow(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(HavenFilter.all.size, key = { HavenFilter.all[it].name }) { i ->
                    val f = HavenFilter.all[i]
                    Text(f.title, color = Color.White, fontSize = 13.sp,
                        fontWeight = if (i == filterIdx) FontWeight.Bold else FontWeight.Normal,
                        modifier = Modifier.clip(RoundedCornerShape(16.dp))
                            .background(if (i == filterIdx) HavenTheme.pink else Color.Black.copy(alpha = 0.4f))
                            .clickable { filterIdx = i }.padding(horizontal = 14.dp, vertical = 8.dp))
                }
            }
            music?.let { m -> Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { MusicChip(m) } }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Row(Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.18f)).clickable { pickSong = true }
                    .padding(horizontal = 16.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null, tint = Color.White, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(if (music == null) "Music" else "Change", color = Color.White, fontSize = 14.sp)
                }
                Text(if (sharing) shareLabel else "Share to story", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(CircleShape).background(HavenTheme.brandHorizontal)
                        .clickable(enabled = !sharing) {
                            sharing = true
                            scope.launch {
                                if (isVideo) {
                                    shareLabel = "Applying filter…"
                                    val newRef = withContext(Dispatchers.IO) {
                                        val inFile = LocalMedia.videoFile(DEFAULT_CIRCLE, ref)
                                        if (inFile == null) ref else {
                                            val out = VideoFilter.transcode(context, inFile, filter.spec) { shareLabel = "Applying filter… ${(it * 100).toInt()}%" }
                                            if (out.absolutePath == inFile.absolutePath) ref
                                            else runCatching { LocalMedia.store(DEFAULT_CIRCLE, out.readBytes(), isVideo = true) }.getOrNull() ?: ref
                                        }
                                    }
                                    HavenNet.postStory(caption.trim(), newRef, music)
                                } else {
                                    val baked = withContext(Dispatchers.IO) {
                                        bakePhoto(srcBmp, filter.spec, caption.trim(), capColor, style, fontIdx, sizeSp, capOffset, boxSize)
                                    }
                                    HavenNet.postStory("", baked ?: ref, music)
                                }
                                onClose()
                            }
                        }.padding(horizontal = 26.dp, vertical = 13.dp))
            }
        }
    }
}

/** Live filter-applied, autoplaying, looping, chrome-free video preview. */
@Composable
private fun EditorVideo(ref: String, spec: FilterSpec, modifier: Modifier) {
    val file = remember(ref) { LocalMedia.videoFile(DEFAULT_CIRCLE, ref) }
    if (file == null) { Box(modifier.background(Color.Black)); return }
    AndroidView(
        modifier = modifier,
        factory = { ctx -> FilteredVideoView(ctx).also { it.play(file); it.setFilter(spec) } },
        update = { it.setFilter(spec) },
        onRelease = { it.release() },
    )
}

@Composable
private fun CtlButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.42f)).clickable { onClick() },
        contentAlignment = Alignment.Center) { content() }
}

/** Bake the GL filter + styled caption into the photo; returns the stored ref (or null on failure). */
private fun bakePhoto(
    srcBmp: Bitmap?, spec: FilterSpec, caption: String, capColor: Color, style: CapStyle,
    fontIdx: Int, sizeSp: Float, capOffset: Offset, boxSize: IntSize,
): String? {
    val src = srcBmp ?: return null
    return runCatching {
        val filtered = GlPhotoFilter.apply(src, spec)
        val out = filtered.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        if (caption.isNotBlank() && boxSize.height > 0) {
            val scale = minOf(boxSize.width.toFloat() / out.width, boxSize.height.toFloat() / out.height)
            val px = if (scale > 0) 1f / scale else 1f
            val textColor = if (style == CapStyle.NEON) android.graphics.Color.WHITE
                else if (style == CapStyle.HIGHLIGHT) contrastOn(capColor).toArgb() else capColor.toArgb()
            val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = textColor; typeface = typefaceFor(fontIdx); textSize = sizeSp * 2.2f * px; textAlign = Paint.Align.CENTER
                when (style) {
                    CapStyle.PLAIN -> setShadowLayer(8f * px, 0f, 2f * px, android.graphics.Color.argb(140, 0, 0, 0))
                    CapStyle.SHADOW -> setShadowLayer(3f * px, 4f * px, 4f * px, android.graphics.Color.argb(220, 0, 0, 0))
                    CapStyle.GLOW -> setShadowLayer(22f * px, 0f, 0f, capColor.toArgb())
                    CapStyle.NEON -> setShadowLayer(28f * px, 0f, 0f, capColor.toArgb())
                    CapStyle.HIGHLIGHT -> {}
                }
            }
            val cx = out.width / 2f + capOffset.x * px
            val cy = out.height / 2f + capOffset.y * px
            val lines = caption.split("\n")
            val lh = tp.fontMetrics.let { it.descent - it.ascent } * 1.15f
            var y = cy - (lines.size - 1) * lh / 2f
            lines.forEach { line ->
                if (style == CapStyle.HIGHLIGHT) {
                    val w = tp.measureText(line)
                    val hp = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = capColor.toArgb() }
                    val pad = 18f * px
                    canvas.drawRoundRect(cx - w / 2 - pad, y + tp.fontMetrics.ascent - 8f * px,
                        cx + w / 2 + pad, y + tp.fontMetrics.descent + 8f * px, 16f * px, 16f * px, hp)
                }
                canvas.drawText(line, cx, y, tp)
                y += lh
            }
        }
        val bytes = ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        LocalMedia.store(DEFAULT_CIRCLE, bytes)
    }.getOrNull()
}
