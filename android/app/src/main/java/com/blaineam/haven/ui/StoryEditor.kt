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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.Shadow
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
    Color(0xFF38BDF8), Color(0xFF34D399), Color(0xFFEF4444))
private val highlightColors = listOf(Color.Transparent, Color.White, Color.Black, Color(0xFFEC4899))
private val fontFamilies = listOf(FontFamily.SansSerif, FontFamily.Serif, FontFamily.Monospace, FontFamily.Cursive)
private fun typefaceFor(i: Int): Typeface = when (i % 4) {
    1 -> Typeface.create(Typeface.SERIF, Typeface.BOLD)
    2 -> Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    3 -> Typeface.create("cursive", Typeface.BOLD)
    else -> Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
}

/**
 * iOS-style story editor: the full 11-filter set (incl. Kodak Gold) on BOTH photos and videos, plus
 * caption controls — color, highlight, font, text size, drag-to-position. Photos preview through the
 * real GLSL filter (offscreen GL); videos preview unfiltered but transcode through the SAME shader on
 * share. The filter + styled caption are baked into the bytes so recipients see the exact composition.
 */
@Composable
fun StoryEditor(ref: String, isVideo: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var caption by remember { mutableStateOf("") }
    var music by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var pickSong by remember { mutableStateOf(false) }
    var capOffset by remember { mutableStateOf(Offset.Zero) }
    var colorIdx by remember { mutableStateOf(0) }
    var highlightIdx by remember { mutableStateOf(0) }
    var fontIdx by remember { mutableStateOf(0) }
    var sizeSp by remember { mutableStateOf(30f) }
    var filterIdx by remember { mutableStateOf(0) }
    var showColors by remember { mutableStateOf(false) }
    var boxSize by remember { mutableStateOf(IntSize.Zero) }
    var sharing by remember { mutableStateOf(false) }
    var shareLabel by remember { mutableStateOf("Share to story") }

    val filter = HavenFilter.all[filterIdx]

    // Source bitmap (photos only) for filter preview + baking.
    var srcBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(ref) {
        if (!isVideo) srcBmp = withContext(Dispatchers.IO) {
            LocalMedia.load(DEFAULT_CIRCLE, ref)?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
        }
    }
    // Live GL-filtered preview of the photo (recomputed when the filter or source changes).
    var previewBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(srcBmp, filterIdx) {
        val s = srcBmp ?: return@LaunchedEffect
        previewBmp = if (filter == HavenFilter.ORIGINAL) s
        else withContext(Dispatchers.Default) { GlPhotoFilter.apply(s, filter.spec) }
    }

    if (pickSong) {
        MusicSearchSheet(onPick = { music = it; pickSong = false }, onDismiss = { pickSong = false })
        return
    }

    val capColor = capColors[colorIdx % capColors.size]
    val highlight = highlightColors[highlightIdx % highlightColors.size]

    Box(Modifier.fillMaxSize().background(Color.Black).onSizeChanged { boxSize = it }) {
        // Media (photo previews filtered; video plays unfiltered, filter bakes on share).
        if (isVideo) {
            VideoTile(DEFAULT_CIRCLE, ref, Modifier.fillMaxSize())
        } else previewBmp?.let { bmp ->
            Image(bmp.asImageBitmap(), "Story", Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }

        // Caption — draggable, styled live.
        Box(
            Modifier.align(Alignment.Center)
                .offset { IntOffset(capOffset.x.toInt(), capOffset.y.toInt()) }
                .pointerInput(Unit) { detectDragGestures { _, drag -> capOffset += drag } }
                .padding(horizontal = 16.dp),
        ) {
            BasicTextField(
                value = caption, onValueChange = { caption = it },
                textStyle = TextStyle(color = capColor, fontSize = sizeSp.sp, fontWeight = FontWeight.Bold,
                    fontFamily = fontFamilies[fontIdx % fontFamilies.size], textAlign = TextAlign.Center,
                    shadow = if (highlight == Color.Transparent) Shadow(Color.Black.copy(alpha = 0.6f), Offset(0f, 2f), 10f) else null),
                cursorBrush = SolidColor(HavenTheme.pink),
                modifier = Modifier.background(highlight, RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp),
                decorationBox = { inner ->
                    if (caption.isEmpty()) Text("Tap to add a caption", color = Color.White.copy(alpha = 0.6f), fontSize = 22.sp)
                    inner()
                },
            )
        }

        // Top bar: close + caption controls.
        Row(Modifier.align(Alignment.TopStart).statusBarsPadding().fillMaxWidth().padding(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            CtlButton({ onClose() }) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
            Spacer(Modifier.weight(1f))
            CtlButton({ showColors = !showColors }) {
                Box(Modifier.size(20.dp).clip(CircleShape).background(capColor).border(1.dp, Color.White, CircleShape))
            }
            Spacer(Modifier.size(8.dp))
            CtlButton({ highlightIdx++ }) { Text("⬛", fontSize = 14.sp) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ fontIdx++ }) { Text("Aa", color = Color.White, fontWeight = FontWeight.Bold) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp - 4f).coerceAtLeast(16f) }) { Text("A−", color = Color.White, fontSize = 13.sp) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp + 4f).coerceAtMost(56f) }) { Text("A+", color = Color.White, fontSize = 15.sp) }
        }

        // Color swatch row (toggled).
        if (showColors) {
            Row(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 64.dp)
                .clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.5f)).padding(8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                capColors.forEachIndexed { i, c ->
                    Box(Modifier.size(26.dp).clip(CircleShape).background(c)
                        .border(if (i == colorIdx) 2.dp else 0.dp, Color.White, CircleShape)
                        .clickable { colorIdx = i; showColors = false })
                }
            }
        }

        // Filter strip — photos AND videos (the same look bakes into either on share).
        LazyRow(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()
            .padding(bottom = 88.dp, start = 8.dp, end = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(HavenFilter.all.size, key = { HavenFilter.all[it].name }) { i ->
                val f = HavenFilter.all[i]
                Text(f.title, color = Color.White, fontSize = 13.sp,
                    fontWeight = if (i == filterIdx) FontWeight.Bold else FontWeight.Normal,
                    modifier = Modifier.clip(RoundedCornerShape(16.dp))
                        .background(if (i == filterIdx) HavenTheme.pink else Color.White.copy(alpha = 0.18f))
                        .clickable { filterIdx = i }.padding(horizontal = 14.dp, vertical = 8.dp))
            }
        }

        music?.let { m -> Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 132.dp)) { MusicChip(m) } }

        // Bottom: music + share.
        Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(16.dp),
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
                                    if (inFile == null) ref
                                    else {
                                        val out = VideoFilter.transcode(context, inFile, filter.spec) {
                                            shareLabel = "Applying filter… ${(it * 100).toInt()}%"
                                        }
                                        if (out.absolutePath == inFile.absolutePath) ref
                                        else runCatching { LocalMedia.store(DEFAULT_CIRCLE, out.readBytes(), isVideo = true) }.getOrNull() ?: ref
                                    }
                                }
                                HavenNet.postStory(caption.trim(), newRef, music)
                            } else {
                                val baked = withContext(Dispatchers.IO) {
                                    bakePhoto(srcBmp, filter.spec, caption.trim(), capColor, highlight, fontIdx, sizeSp, capOffset, boxSize)
                                }
                                HavenNet.postStory("", baked ?: ref, music)
                            }
                            onClose()
                        }
                    }.padding(horizontal = 26.dp, vertical = 13.dp))
        }
    }
}

@Composable
private fun CtlButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f)).clickable { onClick() },
        contentAlignment = Alignment.Center) { content() }
}

/** Bake the GL filter + styled caption into the photo; returns the stored ref (or null on failure). */
private fun bakePhoto(
    srcBmp: Bitmap?, spec: FilterSpec, caption: String, capColor: Color, highlight: Color,
    fontIdx: Int, sizeSp: Float, capOffset: Offset, boxSize: IntSize,
): String? {
    val src = srcBmp ?: return null
    return runCatching {
        // Apply the real filter (same shader as the strip preview), then draw the caption on top.
        val filtered = GlPhotoFilter.apply(src, spec)
        val out = filtered.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        if (caption.isNotBlank() && boxSize.height > 0) {
            val scale = minOf(boxSize.width.toFloat() / out.width, boxSize.height.toFloat() / out.height)
            val px = if (scale > 0) 1f / scale else 1f   // screen px -> image px
            val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = capColor.toArgb(); typeface = typefaceFor(fontIdx)
                textSize = sizeSp * 2.2f * px
                textAlign = Paint.Align.CENTER
                if (highlight == Color.Transparent) setShadowLayer(10f, 0f, 3f, android.graphics.Color.argb(160, 0, 0, 0))
            }
            val cx = out.width / 2f + capOffset.x * px
            val cy = out.height / 2f + capOffset.y * px
            val lines = caption.split("\n")
            val lh = tp.fontMetrics.let { it.descent - it.ascent } * 1.1f
            var y = cy - (lines.size - 1) * lh / 2f
            lines.forEach { line ->
                if (highlight != Color.Transparent) {
                    val w = tp.measureText(line)
                    val hp = Paint().apply { color = highlight.toArgb() }
                    canvas.drawRoundRect(cx - w / 2 - 16f, y + tp.fontMetrics.ascent - 6f,
                        cx + w / 2 + 16f, y + tp.fontMetrics.descent + 6f, 12f, 12f, hp)
                }
                canvas.drawText(line, cx, y, tp)
                y += lh
            }
        }
        val bytes = ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        LocalMedia.store(DEFAULT_CIRCLE, bytes)
    }.getOrNull()
}
