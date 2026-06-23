package com.blaineam.haven.core

/**
 * Turns a verification fingerprint (hex) into a few friendly words so people confirm a connection
 * by comparing words out loud. Byte-exact port of the iOS SafetyWords — same fingerprint yields the
 * same words on both phones, so an Android <-> iPhone verification actually matches.
 */
object SafetyWords {
    private val list = listOf(
        "apple", "amber", "anchor", "aspen", "basil", "bay", "bear", "berry",
        "birch", "bloom", "breeze", "brook", "cedar", "clay", "clover", "cloud",
        "coral", "cove", "crane", "daisy", "dawn", "deer", "dove", "dune",
        "ember", "fern", "finch", "fox", "frost", "garden", "grove", "harbor",
        "hazel", "heron", "honey", "ivy", "lake", "lark", "leaf", "lily",
        "lotus", "maple", "meadow", "mint", "moon", "moss", "olive", "otter",
        "panda", "peach", "pearl", "pine", "poppy", "quail", "rain", "reed",
        "river", "robin", "sage", "shell", "sky", "snow", "sparrow", "spruce",
        "stone", "storm", "sun", "swan", "thistle", "tide", "topaz", "tulip",
        "vale", "violet", "willow", "wren",
    )

    fun words(hex: String, count: Int = 4): List<String> {
        val bytes = ArrayList<Int>(count)
        var i = 0
        while (i + 1 < hex.length && bytes.size < count) {
            hex.substring(i, i + 2).toIntOrNull(16)?.let { bytes.add(it) }
            i += 2
        }
        return bytes.map { list[it % list.size] }
    }

    fun phrase(hex: String, count: Int = 4): String = words(hex, count).joinToString(" · ")
}
