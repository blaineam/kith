package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material.icons.filled.AddPhotoAlternate
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.PendingRequest
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.core.nowMs
import uniffi.haven_ffi.FeedItemFfi

/** The Circle (feed) — real posts from the shared engine, a composer, and pending requests. */
@Composable
fun CircleScreen(onAddFriend: () -> Unit) {
    val context = LocalContext.current
    var draft by remember { mutableStateOf("") }
    var pendingPhoto by remember { mutableStateOf<String?>(null) }   // media id staged for the next post
    val profile = remember { com.blaineam.haven.core.ProfileStore.get(context) }
    val version by HavenNet.feedVersion          // recompose when the feed changes
    val items: List<FeedItemFfi> = remember(version, profile.retentionDays) {
        runCatching { HavenNet.engine.feed(DEFAULT_CIRCLE, nowMs(), profile.retentionSecs()) }.getOrDefault(emptyList())
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            val bytes = loadAndDownscale(context, uri)
            if (bytes != null) pendingPhoto = LocalMedia.store(DEFAULT_CIRCLE, bytes)
        }
    }

    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            // Title bar.
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BrandText("Circle", fontSize = 26)
                Spacer(Modifier.weight(1f))
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { onAddFriend() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.PersonAdd, "Add a friend", tint = HavenTheme.pink) }
            }

            if (HavenNet.pending.isNotEmpty()) {
                HavenNet.pending.forEach { PendingCard(it) }
            }

            if (items.isEmpty()) {
                Column(
                    Modifier.fillMaxWidth().weight(1f).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text("Nothing here yet", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (HavenNet.contacts.isEmpty())
                            "Add a friend to start sharing.\nEverything you post is end-to-end encrypted to your circle."
                        else "Say something to your circle below.",
                        color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center,
                    )
                }
            } else {
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    items(items, key = { it.id }) { PostCard(it) }
                }
            }

            // Staged photo preview.
            pendingPhoto?.let { id ->
                Box(Modifier.padding(start = 16.dp, bottom = 4.dp)) {
                    MediaImage(DEFAULT_CIRCLE, id, Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)))
                    Text("✕", color = Color.White, fontSize = 16.sp,
                        modifier = Modifier.align(Alignment.TopEnd).clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f)).clickable { pendingPhoto = null }
                            .padding(horizontal = 6.dp))
                }
            }
            // Composer.
            Row(
                Modifier.fillMaxWidth().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(44.dp).clip(CircleShape).clickable {
                        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.AddPhotoAlternate, "Add photo", tint = HavenTheme.pink) }
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("Share with your circle…") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(22.dp),
                    maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink,
                        cursorColor = HavenTheme.pink,
                    ),
                )
                Spacer(Modifier.size(8.dp))
                val canPost = draft.isNotBlank() || pendingPhoto != null
                Box(
                    Modifier.size(48.dp).clip(CircleShape)
                        .background(HavenTheme.brandHorizontal)
                        .clickable(enabled = canPost) {
                            HavenNet.post(DEFAULT_CIRCLE, draft.trim(), listOfNotNull(pendingPhoto))
                            draft = ""; pendingPhoto = null
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Post", tint = Color.White) }
            }
        }
    }
}

@Composable
private fun PendingCard(req: PendingRequest) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .havenCard().padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("${req.name} wants to connect", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("Safety: ${req.verifyHex.take(12)}…", color = HavenTheme.textSecondary, fontSize = 11.sp)
        }
        Text("Accept", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.approve(req) }.padding(8.dp))
        Text("Ignore", color = HavenTheme.textSecondary,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.dismiss(req) }.padding(8.dp))
    }
}

/** Decode a stored (sealed) media id into an Image, off the main thread. Shows nothing until ready. */
@Composable
fun MediaImage(circleId: String, id: String, modifier: Modifier = Modifier) {
    var bmp by remember(id) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(id, circleId) {
        bmp = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val bytes = LocalMedia.load(circleId, id) ?: return@withContext null
            runCatching {
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }.getOrNull()
        }
    }
    bmp?.let { Image(it, contentDescription = "Photo", modifier = modifier, contentScale = ContentScale.FillWidth) }
}

private val QUICK_EMOJI = listOf("❤️", "😂", "🔥", "👍", "🎉", "😮")

@Composable
fun PostCard(item: FeedItemFfi, circleId: String = DEFAULT_CIRCLE) {
    var showComment by remember(item.id) { mutableStateOf(false) }
    var commentDraft by remember(item.id) { mutableStateOf("") }
    var showPicker by remember(item.id) { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(HavenTheme.brand),
                contentAlignment = Alignment.Center,
            ) { Text(if (item.isMe) "•" else item.authorShort.take(1).uppercase(), color = Color.White, fontSize = 14.sp) }
            Spacer(Modifier.size(10.dp))
            Text(
                if (item.isMe) "You" else item.authorShort,
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
        }
        if (item.body.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            Text(item.body, color = Color.White, fontSize = 15.sp)
        }

        // Attached photos.
        item.media.forEach { id ->
            Spacer(Modifier.height(10.dp))
            MediaImage(circleId, id, Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)))
        }

        // Existing reactions.
        if (item.reactions.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                item.reactions.forEach { r ->
                    val mine = r.mine
                    Box(
                        Modifier.clip(RoundedCornerShape(20.dp))
                            .background(if (mine) HavenTheme.pink.copy(alpha = 0.25f) else HavenTheme.background)
                            .clickable {
                                if (mine) HavenNet.unreact(circleId, item.id, r.emoji)
                                else HavenNet.react(circleId, item.id, r.emoji)
                            }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    ) { Text("${r.emoji} ${r.count}", fontSize = 13.sp, color = Color.White) }
                }
            }
        }

        // Action bar: react + comment.
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("React", color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showPicker = !showPicker }.padding(6.dp))
            Spacer(Modifier.size(8.dp))
            Text("Comment", color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showComment = !showComment }.padding(6.dp))
        }
        if (showPicker) {
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                QUICK_EMOJI.forEach { e ->
                    Box(
                        Modifier.clip(CircleShape).clickable {
                            HavenNet.react(circleId, item.id, e); showPicker = false
                        }.padding(6.dp),
                    ) { Text(e, fontSize = 22.sp) }
                }
            }
        }

        // Comments.
        if (item.comments.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            item.comments.forEach { c ->
                Row(Modifier.padding(vertical = 2.dp)) {
                    Text(if (c.isMe) "You: " else "${c.authorShort}: ",
                        color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(c.body, color = Color.White, fontSize = 13.sp)
                }
            }
        }
        if (showComment) {
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = commentDraft, onValueChange = { commentDraft = it },
                    placeholder = { Text("Add a comment…", fontSize = 13.sp) },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Text("Send", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                        HavenNet.comment(circleId, item.id, commentDraft.trim())
                        commentDraft = ""; showComment = false
                    }.padding(10.dp))
            }
        }
    }
}
