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
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Videocam
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
import androidx.compose.ui.viewinterop.AndroidView
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
    var pendingMusic by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var showMusicDialog by remember { mutableStateOf(false) }
    // A link shared into Haven from another app prefills the composer.
    val sharedText = com.blaineam.haven.core.ShareInbox.pending
    LaunchedEffect(sharedText) {
        if (!sharedText.isNullOrBlank()) {
            draft = if (draft.isBlank()) sharedText else "$draft $sharedText"
            com.blaineam.haven.core.ShareInbox.take()
        }
    }
    val profile = remember { com.blaineam.haven.core.ProfileStore.get(context) }
    val version by HavenNet.feedVersion          // recompose when the feed changes
    val items: List<FeedItemFfi> = remember(version, profile.retentionDays) {
        runCatching { HavenNet.engine.feed(DEFAULT_CIRCLE, nowMs(), profile.retentionSecs()) }.getOrDefault(emptyList())
    }
    val storyGroups = remember(items) { groupStories(items) }
    val posts = remember(items) { items.filter { !it.story } }
    var viewingStory by remember { mutableStateOf<Int?>(null) }
    var showStoryCamera by remember { mutableStateOf(false) }
    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showStoryCamera = true
    }
    fun openStoryCamera() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) showStoryCamera = true
        else camPermission.launch(android.Manifest.permission.CAMERA)
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            if (com.blaineam.haven.core.isVideoUri(context, uri)) {
                val bytes = com.blaineam.haven.core.readVideoBytes(context, uri)
                if (bytes != null) pendingPhoto = LocalMedia.store(DEFAULT_CIRCLE, bytes, isVideo = true)
            } else {
                val bytes = loadAndDownscale(context, uri)
                if (bytes != null) pendingPhoto = LocalMedia.store(DEFAULT_CIRCLE, bytes)
            }
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
                ConnectionDot()
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { onAddFriend() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.PersonAdd, "Add a friend", tint = HavenTheme.pink) }
            }

            // Stories tray (rings) — always shown so you can add your own.
            StoriesTray(
                groups = storyGroups,
                onAddStory = { openStoryCamera() },
                onOpen = { viewingStory = it },
            )

            if (HavenNet.pending.isNotEmpty()) {
                HavenNet.pending.forEach { PendingCard(it) }
            }

            if (posts.isEmpty()) {
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
                    items(posts, key = { it.id }) { PostCard(it) }
                }
            }

            // Staged photo preview.
            pendingPhoto?.let { ref ->
                Box(Modifier.padding(start = 16.dp, bottom = 4.dp)) {
                    if (LocalMedia.isVideo(ref)) {
                        Box(Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)).background(HavenTheme.card),
                            contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.Videocam, "Video", tint = Color.White)
                        }
                    } else {
                        MediaImage(DEFAULT_CIRCLE, ref, Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)))
                    }
                    Text("✕", color = Color.White, fontSize = 16.sp,
                        modifier = Modifier.align(Alignment.TopEnd).clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f)).clickable { pendingPhoto = null }
                            .padding(horizontal = 6.dp))
                }
            }
            // Staged music chip.
            pendingMusic?.let { m ->
                Row(Modifier.padding(start = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("${m.title} · ${m.artist}", color = Color.White, fontSize = 12.sp, maxLines = 1)
                    Spacer(Modifier.size(8.dp))
                    Text("✕", color = HavenTheme.textSecondary, fontSize = 14.sp,
                        modifier = Modifier.clickable { pendingMusic = null })
                }
            }
            // Composer.
            Row(
                Modifier.fillMaxWidth().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(44.dp).clip(CircleShape).clickable {
                        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                    },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.AddPhotoAlternate, "Add photo or video", tint = HavenTheme.pink) }
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { showMusicDialog = true },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.MusicNote, "Add a song", tint = HavenTheme.pink) }
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
                val canPost = draft.isNotBlank() || pendingPhoto != null || pendingMusic != null
                Box(
                    Modifier.size(48.dp).clip(CircleShape)
                        .background(HavenTheme.brandHorizontal)
                        .clickable(enabled = canPost) {
                            HavenNet.post(DEFAULT_CIRCLE, draft.trim(), listOfNotNull(pendingPhoto), pendingMusic)
                            draft = ""; pendingPhoto = null; pendingMusic = null
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Post", tint = Color.White) }
            }
        }

        // Full-screen story viewer overlay.
        viewingStory?.let { start ->
            StoryViewer(groups = storyGroups, startGroup = start, onClose = { viewingStory = null })
        }
        // In-app story camera overlay.
        if (showStoryCamera) {
            StoryCameraScreen(onClose = { showStoryCamera = false })
        }
    }

    if (showMusicDialog) {
        var link by remember { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showMusicDialog = false },
            containerColor = HavenTheme.card,
            title = { Text("Add a song", color = Color.White) },
            text = {
                Column {
                    Text("Paste a YouTube, Spotify, or Apple Music link. It rides along with your post.",
                        color = HavenTheme.textSecondary, fontSize = 13.sp)
                    Spacer(Modifier.height(10.dp))
                    OutlinedTextField(
                        value = link, onValueChange = { link = it }, singleLine = true,
                        placeholder = { Text("https://…") }, modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                    )
                }
            },
            confirmButton = {
                androidx.compose.material3.TextButton(
                    enabled = link.isNotBlank(),
                    onClick = {
                        val domain = runCatching { java.net.URL(link.trim()).host.removePrefix("www.") }.getOrDefault("link")
                        pendingMusic = HavenNet.trackFromLink(link.trim(), "Song", domain)
                        showMusicDialog = false
                    },
                ) { Text("Attach", color = HavenTheme.pink) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { showMusicDialog = false }) {
                    Text("Cancel", color = HavenTheme.textSecondary)
                }
            },
        )
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
            Text("Safety: ${com.blaineam.haven.core.SafetyWords.phrase(req.verifyHex)}",
                color = HavenTheme.textSecondary, fontSize = 11.sp)
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

/** Live connection status: online (iroh) + relay (mailbox) dots, like the iOS connection chips. */
@Composable
private fun ConnectionDot() {
    val online by HavenNet.internetActive
    val started by HavenNet.started
    val relay by HavenNet.relayActive
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(end = 8.dp)) {
        val color = if (online) Color(0xFF34D399) else if (started) Color(0xFFF59E0B) else HavenTheme.textSecondary
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(if (online) "Online" else if (started) "Connecting" else "Offline",
            color = HavenTheme.textSecondary, fontSize = 11.sp)
        if (relay) {
            Text("· Relay", color = Color(0xFF34D399), fontSize = 11.sp)
        }
    }
}

/** Plays an attached video from its decrypted cache file (tap to start), with controls. */
@Composable
fun VideoTile(circleId: String, ref: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var file by remember(ref) { mutableStateOf<java.io.File?>(null) }
    LaunchedEffect(ref, circleId) {
        file = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            LocalMedia.videoFile(circleId, ref)
        }
    }
    val f = file
    if (f == null) {
        Box(modifier.background(HavenTheme.card).padding(40.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Videocam, "Video", tint = HavenTheme.textSecondary)
        }
    } else {
        AndroidView(
            modifier = modifier,
            factory = { ctx ->
                android.widget.VideoView(ctx).apply {
                    setVideoPath(f.absolutePath)
                    val mc = android.widget.MediaController(ctx)
                    mc.setAnchorView(this)
                    setMediaController(mc)
                    setOnPreparedListener { it.isLooping = true }
                }
            },
        )
    }
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
            ) {
                val authorName = if (item.isMe) "You" else HavenNet.displayName(item.authorShort)
                Text(if (item.isMe) "•" else authorName.take(1).uppercase(), color = Color.White, fontSize = 14.sp)
            }
            Spacer(Modifier.size(10.dp))
            Text(
                if (item.isMe) "You" else HavenNet.displayName(item.authorShort),
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
        }
        if (item.body.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            LinkedText(item.body, color = Color.White, fontSize = 15.sp)
            LinkPreviewCard(item.body, Modifier.padding(top = 10.dp))
        }

        // Attached photos / videos.
        item.media.forEach { ref ->
            Spacer(Modifier.height(10.dp))
            if (LocalMedia.isVideo(ref)) {
                VideoTile(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)))
            } else {
                MediaImage(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)))
            }
        }

        // Attached song.
        item.music?.let { m ->
            val ctx = LocalContext.current
            Spacer(Modifier.height(10.dp))
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(HavenTheme.background)
                    .clickable { if (m.catalogId.isNotBlank()) openInApp(ctx, m.catalogId) }.padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink, modifier = Modifier.size(22.dp))
                Spacer(Modifier.size(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(m.title, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    if (m.artist.isNotBlank()) Text(m.artist, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 1)
                }
                Text("Play", color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
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
            var customEmoji by remember(item.id) { mutableStateOf("") }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                QUICK_EMOJI.forEach { e ->
                    Box(
                        Modifier.clip(CircleShape).clickable {
                            HavenNet.react(circleId, item.id, e); showPicker = false
                        }.padding(6.dp),
                    ) { Text(e, fontSize = 22.sp) }
                }
            }
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = customEmoji,
                    onValueChange = { customEmoji = it },
                    placeholder = { Text("Any emoji…", fontSize = 13.sp) },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Text("Add", color = if (customEmoji.isNotBlank()) HavenTheme.pink else HavenTheme.textSecondary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = customEmoji.isNotBlank()) {
                        HavenNet.react(circleId, item.id, customEmoji.trim()); customEmoji = ""; showPicker = false
                    }.padding(10.dp))
            }
        }

        // Comments.
        if (item.comments.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            item.comments.forEach { c ->
                Row(Modifier.padding(vertical = 2.dp)) {
                    Text(if (c.isMe) "You: " else "${HavenNet.displayName(c.authorShort)}: ",
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
