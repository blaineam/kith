package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** Locks the safe-words mapping to the iOS SafetyWords so a cross-platform verification matches. */
class SafetyWordsTest {
    @Test fun maps_bytes_to_words_like_ios() {
        // 76-word list; byte % 76 selects. 0x00 -> apple, 0x01 -> amber, 0x4c(76) wraps -> apple.
        assertEquals(listOf("apple", "amber", "anchor", "aspen"), SafetyWords.words("00010203"))
        assertEquals("apple", SafetyWords.words("4c").first())   // 76 % 76 == 0
        assertEquals("amber", SafetyWords.words("4d").first())   // 77 % 76 == 1
    }

    @Test fun takes_first_n_byte_pairs() {
        assertEquals(4, SafetyWords.words("aabbccddeeff0011", count = 4).size)
        assertEquals(3, SafetyWords.words("aabbcc", count = 4).size)
    }

    @Test fun phrase_joins_with_separator() {
        assertEquals("apple · amber", SafetyWords.phrase("0001", count = 2))
    }
}
