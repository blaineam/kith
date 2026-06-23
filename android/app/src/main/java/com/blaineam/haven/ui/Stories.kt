package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.DEFAULT_CIRCLE
import kotlinx.coroutines.delay
import uniffi.haven_ffi.FeedItemFfi

/** One author's active stories, grouped for the tray + viewer. */
data class StoryGroup(val authorShort: String, val isMe: Boolean, val items: List<FeedItemFfi>)

fun groupStories(items: List<FeedItemFfi>): List<StoryGroup> =
    items.filter { it.story }
        .groupBy { it.authorShort }
        .map { (author, list) ->
            StoryGroup(author, list.first().isMe, list.sortedBy { it.createdAt })
        }
        .sortedByDescending { it.isMe }

/** Horizontal ring tray at the top of the feed. The first ring is "your story" (+). */
@Composable
fun StoriesTray(groups: List<StoryGroup>, onAddStory: () -> Unit, onOpen: (Int) -> Unit) {
    LazyRow(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape).background(HavenTheme.card).clickable { onAddStory() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Add, "Add to your story", tint = HavenTheme.pink) }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text("Your story", color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
        }
        items(groups.size) { idx ->
            val g = groups[idx]
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape)
                        .background(HavenTheme.brand).clickable { onOpen(idx) },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier.size(56.dp).clip(CircleShape).background(HavenTheme.card),
                        contentAlignment = Alignment.Center,
                    ) {
                        val first = g.items.firstOrNull()
                        val mediaId = first?.media?.firstOrNull()
                        if (mediaId != null) {
                            MediaImage(DEFAULT_CIRCLE, mediaId, Modifier.size(56.dp).clip(CircleShape))
                        } else {
                            androidx.compose.material3.Text(
                                if (g.isMe) "You" else g.authorShort.take(2),
                                color = Color.White, fontSize = 13.sp,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text(
                    if (g.isMe) "You" else com.blaineam.haven.core.HavenNet.displayName(g.authorShort),
                    color = Color.White, fontSize = 11.sp, maxLines = 1,
                )
            }
        }
    }
}

/** Full-screen story viewer: progress bars, tap right/left to advance, auto-advance. */
@Composable
fun StoryViewer(groups: List<StoryGroup>, startGroup: Int, onClose: () -> Unit) {
    var groupIdx by remember { mutableIntStateOf(startGroup) }
    var itemIdx by remember { mutableIntStateOf(0) }
    val group = groups.getOrNull(groupIdx) ?: run { onClose(); return }
    val item = group.items.getOrNull(itemIdx) ?: run { onClose(); return }

    fun advance() {
        if (itemIdx + 1 < group.items.size) itemIdx++
        else if (groupIdx + 1 < groups.size) { groupIdx++; itemIdx = 0 }
        else onClose()
    }
    fun back() {
        if (itemIdx > 0) itemIdx--
        else if (groupIdx > 0) { groupIdx--; itemIdx = 0 }
    }

    // Auto-advance every 5s.
    LaunchedEffect(groupIdx, itemIdx) {
        delay(5000)
        advance()
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .pointerInput(groupIdx, itemIdx) {
                detectTapGestures(
                    onTap = { o -> if (o.x > size.width / 2) advance() else back() },
                    onLongPress = { onClose() },
                )
            },
    ) {
        val mediaId = item.media.firstOrNull()
        if (mediaId != null) {
            MediaImage(DEFAULT_CIRCLE, mediaId, Modifier.fillMaxSize())
        }
        if (item.body.isNotBlank()) {
            androidx.compose.material3.Text(
                item.body, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.Center).padding(28.dp),
            )
        }
        // Progress bars (one per story in this group).
        Row(
            Modifier.fillMaxWidth().padding(top = 14.dp, start = 10.dp, end = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            group.items.indices.forEach { i ->
                Box(
                    Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp))
                        .background(if (i <= itemIdx) Color.White else Color.White.copy(alpha = 0.3f)),
                )
            }
        }
        androidx.compose.material3.Text(
            if (group.isMe) "You" else com.blaineam.haven.core.HavenNet.displayName(group.authorShort),
            color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.TopStart).padding(start = 14.dp, top = 28.dp),
        )
        androidx.compose.material3.Text(
            "✕", color = Color.White, fontSize = 22.sp,
            modifier = Modifier.align(Alignment.TopEnd).padding(16.dp).clickable { onClose() },
        )
    }
}
