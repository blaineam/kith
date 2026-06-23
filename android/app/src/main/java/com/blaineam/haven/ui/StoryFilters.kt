package com.blaineam.haven.ui

/** Photo filter presets — a name + a 4x5 color matrix used both for the live preview and baking. */
data class StoryFilter(val name: String, val matrix: FloatArray)

val storyFilters: List<StoryFilter> = listOf(
    StoryFilter("Original", floatArrayOf(
        1f, 0f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f, 0f,
        0f, 0f, 1f, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )),
    StoryFilter("Noir", saturation(0f)),
    StoryFilter("Vivid", saturation(1.6f)),
    StoryFilter("Sepia", floatArrayOf(
        0.393f, 0.769f, 0.189f, 0f, 0f,
        0.349f, 0.686f, 0.168f, 0f, 0f,
        0.272f, 0.534f, 0.131f, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )),
    StoryFilter("Warm", floatArrayOf(
        1.15f, 0f, 0f, 0f, 12f,
        0f, 1.05f, 0f, 0f, 6f,
        0f, 0f, 0.9f, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )),
    StoryFilter("Cool", floatArrayOf(
        0.9f, 0f, 0f, 0f, 0f,
        0f, 1.0f, 0f, 0f, 4f,
        0f, 0f, 1.2f, 0f, 14f,
        0f, 0f, 0f, 1f, 0f,
    )),
    StoryFilter("Fade", floatArrayOf(
        0.8f, 0f, 0f, 0f, 30f,
        0f, 0.8f, 0f, 0f, 30f,
        0f, 0f, 0.8f, 0f, 30f,
        0f, 0f, 0f, 1f, 0f,
    )),
)

/** A grayscale-weighted saturation matrix (s=0 → B&W, s>1 → vivid). */
private fun saturation(s: Float): FloatArray {
    val rw = 0.213f; val gw = 0.715f; val bw = 0.072f
    val a = (1 - s)
    return floatArrayOf(
        a * rw + s, a * gw, a * bw, 0f, 0f,
        a * rw, a * gw + s, a * bw, 0f, 0f,
        a * rw, a * gw, a * bw + s, 0f, 0f,
        0f, 0f, 0f, 1f, 0f,
    )
}
