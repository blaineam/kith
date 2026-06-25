package com.blaineam.haven.ui

import androidx.compose.ui.graphics.Color

/**
 * Decodes an iOS-authored story caption so it renders styled instead of as raw gibberish. Wire
 * format (apple/HavenApp/StoryCaption.swift):
 *    color,font,styleRaw,x,y,size,mediaScale,mediaOffX,mediaOffY  text
 * A plain body (no  prefix) is just the text.
 */
object StoryCaptions {
    // Must match iOS StoryCaptions.colors index-for-index (the color rides as an index on the wire).
    private val colors = listOf(
        Color.White, Color.Black, Color(0xFFEC4899), Color(0xFF8B5CF6), Color(0xFFF59E0B),
        Color(0xFFEF4444), Color(0xFFF97316), Color(0xFF22C55E), Color(0xFF3B82F6),
        Color(0xFF06B6D4), Color(0xFFEAB308), Color(0xFF10B981),
    )

    // iOS Style raw values: 0 plain · 1 glow · 2 shadow · 3 neon · 4 highlight.
    enum class CapStyle { PLAIN, GLOW, SHADOW, NEON, HIGHLIGHT }

    data class Spec(
        val colorIdx: Int = 0,
        val style: CapStyle = CapStyle.GLOW,
        val x: Float = 0.5f,
        val y: Float = 0.5f,
        val size: Float = 1f,
    )
    data class Decoded(val text: String, val spec: Spec)

    fun decode(body: String): Decoded {
        if (!body.startsWith("\u0001")) return Decoded(body, Spec())
        val rest = body.substring(1)
        val sep = rest.indexOf('\u0001')
        if (sep < 0) return Decoded(rest, Spec())
        val n = rest.substring(0, sep).split(",")
        val text = rest.substring(sep + 1)
        var styleRaw = n.getOrNull(2)?.toIntOrNull() ?: 1
        // Back-compat: older stories stored a 0/1 highlight bit in exactly 6 fields.
        if ((styleRaw == 0 || styleRaw == 1) && n.size == 6) styleRaw = if (styleRaw == 1) 4 else 1
        val style = when (styleRaw) {
            0 -> CapStyle.PLAIN; 1 -> CapStyle.GLOW; 2 -> CapStyle.SHADOW; 3 -> CapStyle.NEON
            4 -> CapStyle.HIGHLIGHT; else -> CapStyle.GLOW
        }
        return Decoded(
            text,
            Spec(
                colorIdx = n.getOrNull(0)?.toIntOrNull() ?: 0,
                style = style,
                x = n.getOrNull(3)?.toFloatOrNull() ?: 0.5f,
                y = n.getOrNull(4)?.toFloatOrNull() ?: 0.5f,
                size = n.getOrNull(5)?.toFloatOrNull() ?: 1f,
            ),
        )
    }

    fun color(idx: Int): Color = colors[idx.coerceIn(0, colors.size - 1)]
    /** Highlight text needs a contrasting fill: dark text on light colors (white/cyan/yellow/mint). */
    fun highlightTextColor(idx: Int): Color =
        if (idx.coerceIn(0, colors.size - 1) in listOf(0, 9, 10, 11)) Color.Black else Color.White
}
