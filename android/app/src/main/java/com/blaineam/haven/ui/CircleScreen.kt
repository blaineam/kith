package com.blaineam.haven.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.PlayCircle
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
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.foundation.lazy.grid.items as gridItems
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.PendingRequest
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.core.nowMs
import kotlinx.coroutines.launch
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
    val circlesVersion by HavenNet.circlesVersion
    val active by HavenNet.activeCircle
    val items: List<FeedItemFfi> = remember(version, active, profile.retentionDays) {
        runCatching { HavenNet.engine.feed(active, nowMs(), profile.retentionSecs()) }.getOrDefault(emptyList())
    }
    val storyGroups = remember(items) { groupStories(items) }
    val posts = remember(items) { items.filter { !it.story } }
    var viewingStory by remember { mutableStateOf<Int?>(null) }
    var showStoryCamera by remember { mutableStateOf(false) }
    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants[android.Manifest.permission.CAMERA] == true) showStoryCamera = true
    }
    fun openStoryCamera() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) showStoryCamera = true
        else camPermission.launch(arrayOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO))
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            if (com.blaineam.haven.core.isVideoUri(context, uri)) {
                val bytes = com.blaineam.haven.core.readVideoBytes(context, uri)
                if (bytes != null) pendingPhoto = LocalMedia.store(HavenNet.activeCircle.value, bytes, isVideo = true)
            } else {
                val bytes = loadAndDownscale(context, uri)
                if (bytes != null) pendingPhoto = LocalMedia.store(HavenNet.activeCircle.value, bytes)
            }
        }
    }

    HavenBackground {
        Column(Modifier.fillMaxSize().imePadding()) {
            // Title bar (compact — every vertical pixel counts on phones).
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 10.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircleSwitcher(active, circlesVersion)
                Spacer(Modifier.weight(1f))
                ConnectionDot()
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { onAddFriend() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.PersonAdd, "Add a friend", tint = HavenTheme.pink) }
            }

            val lockV by com.blaineam.haven.core.CircleLock.version
            val locked = remember(active, lockV) { com.blaineam.haven.core.CircleLock.needsUnlock(active) }
            if (locked) {
                // A locked circle hides EVERYTHING in it — stories, posts and the composer — until unlock.
                Column(Modifier.fillMaxWidth().weight(1f).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text("🔒", fontSize = 48.sp)
                    Spacer(Modifier.height(12.dp))
                    Text("This circle is locked", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text("Stories, posts and messages stay hidden until you unlock.",
                        color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(16.dp))
                    BrandButton(text = "Unlock", modifier = Modifier.fillMaxWidth(0.6f)) {
                        (context as? androidx.fragment.app.FragmentActivity)?.let {
                            com.blaineam.haven.core.CircleLock.authenticate(it, active) {}
                        }
                    }
                }
            } else {
                // Stories + pending scroll WITH the posts so there's maximum room to browse.
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item { StoriesTray(groups = storyGroups, onAddStory = { openStoryCamera() }, onOpen = { viewingStory = it }) }
                    if (HavenNet.pending.isNotEmpty()) item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { HavenNet.pending.forEach { PendingCard(it) } }
                    }
                    if (posts.isEmpty()) item {
                        Column(Modifier.fillMaxWidth().height(260.dp).padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            Text("Nothing here yet", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.height(8.dp))
                            Text(
                                if (HavenNet.contacts.isEmpty())
                                    "Add a friend to start sharing.\nEverything you post is end-to-end encrypted to your circle."
                                else "Say something to your circle below.",
                                color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center,
                            )
                        }
                    } else items(posts, key = { it.id }) { PostCard(it, active) }
                }
            }

            if (!locked) {
            // Staged photo preview.
            pendingPhoto?.let { ref ->
                Box(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                    if (LocalMedia.isVideo(ref)) {
                        Box(Modifier.fillMaxWidth().height(160.dp)
                            .clip(RoundedCornerShape(14.dp)).background(HavenTheme.card),
                            contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.Videocam, "Video attached", tint = Color.White, modifier = Modifier.size(40.dp))
                        }
                    } else {
                        MediaImage(active, ref,
                            Modifier.fillMaxWidth().height(160.dp)
                                .clip(RoundedCornerShape(14.dp)),
                            contentScale = ContentScale.Crop)
                    }
                    Text("✕", color = Color.White, fontSize = 18.sp,
                        modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f)).clickable { pendingPhoto = null }
                            .padding(horizontal = 8.dp, vertical = 2.dp))
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
                            HavenNet.post(active, draft.trim(), listOfNotNull(pendingPhoto), pendingMusic)
                            draft = ""; pendingPhoto = null; pendingMusic = null
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Post", tint = Color.White) }
            }
            }
        }

    }

    // Full-screen overlays (a borderless Dialog draws above the tab bar — true full-screen).
    viewingStory?.let { start ->
        FullScreenOverlay(onDismiss = { viewingStory = null }) {
            StoryViewer(groups = storyGroups, startGroup = start, onClose = { viewingStory = null })
        }
    }
    if (showStoryCamera) {
        FullScreenOverlay(onDismiss = { showStoryCamera = false }) {
            StoryCameraScreen(onClose = { showStoryCamera = false })
        }
    }
    if (showMusicDialog) {
        FullScreenOverlay(onDismiss = { showMusicDialog = false }) {
            MusicSearchSheet(
                onPick = { track -> pendingMusic = track; showMusicDialog = false },
                onDismiss = { showMusicDialog = false },
            )
        }
    }
}

/** Hosts content in a borderless full-screen dialog window so it covers the bottom tab bar too. */
@Composable
fun FullScreenOverlay(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.DialogProperties(
            usePlatformDefaultWidth = false, dismissOnClickOutside = false,
        ),
    ) {
        Box(Modifier.fillMaxSize().background(HavenTheme.background)) { content() }
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
fun MediaImage(circleId: String, id: String, modifier: Modifier = Modifier,
               contentScale: ContentScale = ContentScale.FillWidth) {
    var bmp by remember(id) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(id, circleId) {
        bmp = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val bytes = LocalMedia.load(circleId, id) ?: return@withContext null
            runCatching {
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }.getOrNull()
        }
    }
    bmp?.let { Image(it, contentDescription = "Photo", modifier = modifier, contentScale = contentScale) }
        ?: Box(modifier.background(HavenTheme.card), contentAlignment = Alignment.Center) {
            androidx.compose.material3.CircularProgressIndicator(
                color = HavenTheme.pink, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
        }
}

/** A small media thumbnail (image or a video tile with a play glyph), tappable to open. */
@Composable
private fun MediaThumb(circleId: String, ref: String, modifier: Modifier, onOpen: () -> Unit) {
    Box(modifier.clip(RoundedCornerShape(12.dp)).clickable { onOpen() }) {
        MediaImage(circleId, ref, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        if (LocalMedia.isVideo(ref)) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.PlayCircle, "Play", tint = Color.White, modifier = Modifier.size(40.dp))
            }
        }
    }
}

/** Post media: a single item fills the card; multiple items scroll as a 2-row grid (like iOS). */
@Composable
fun MediaGallery(circleId: String, refs: List<String>, onOpen: (Int) -> Unit) {
    if (refs.size == 1) {
        MediaThumb(circleId, refs[0], Modifier.fillMaxWidth().height(240.dp)) { onOpen(0) }
        return
    }
    androidx.compose.foundation.lazy.grid.LazyHorizontalGrid(
        rows = androidx.compose.foundation.lazy.grid.GridCells.Fixed(2),
        modifier = Modifier.fillMaxWidth().height(264.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        gridItems(refs) { ref ->
            MediaThumb(circleId, ref, Modifier.size(129.dp)) { onOpen(refs.indexOf(ref)) }
        }
    }
}

/** Full-screen media viewer: swipe between items, tap/back to close. */
@Composable
fun MediaViewer(circleId: String, refs: List<String>, startIndex: Int, onClose: () -> Unit) {
    val pager = androidx.compose.foundation.pager.rememberPagerState(initialPage = startIndex) { refs.size }
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var saved by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize().background(Color.Black).clickable { onClose() }) {
        androidx.compose.foundation.pager.HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
            val ref = refs[page]
            if (LocalMedia.isVideo(ref)) VideoTile(circleId, ref, Modifier.fillMaxSize())
            else MediaImage(circleId, ref, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
        Box(Modifier.align(Alignment.TopStart).padding(16.dp).size(42.dp).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.4f)).clickable { onClose() }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Close, "Close", tint = Color.White)
        }
        // Save this item to Photos.
        Box(Modifier.align(Alignment.TopEnd).padding(16.dp).size(42.dp).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.4f)).clickable {
                val ref = refs[pager.currentPage]
                scope.launch {
                    saved = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        LocalMedia.loadAnyCircle(ref)?.let { com.blaineam.haven.core.MediaSaver.save(context, it, LocalMedia.isVideo(ref)) } ?: false
                    }
                }
            }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Download, "Save to Photos", tint = Color.White)
        }
        if (refs.size > 1) Text("${pager.currentPage + 1} / ${refs.size}", color = Color.White, fontSize = 13.sp,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 24.dp))
        if (saved) {
            LaunchedEffect(Unit) { kotlinx.coroutines.delay(1500); saved = false }
            Text("Saved to Photos ✓", color = Color.White, fontSize = 13.sp,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 40.dp).clip(RoundedCornerShape(20.dp))
                    .background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 8.dp))
        }
    }
}

/** Feed-circle switcher: tap the title for a dropdown of your circles + "New circle". */
@Composable
private fun CircleSwitcher(activeId: String, circlesVersion: Int) {
    var menu by remember { mutableStateOf(false) }
    var showCreate by remember { mutableStateOf(false) }
    val circles = remember(circlesVersion) { HavenNet.feedCircles() }
    val name = remember(activeId, circlesVersion) { HavenNet.circleName(activeId) }
    Box {
        Row(verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable { menu = true }) {
            BrandText(name, fontSize = 24)
            Icon(androidx.compose.material.icons.Icons.Filled.ArrowDropDown, "Switch circle", tint = HavenTheme.pink)
        }
        androidx.compose.material3.DropdownMenu(
            expanded = menu, onDismissRequest = { menu = false }, modifier = Modifier.background(HavenTheme.card),
        ) {
            circles.forEach { c ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("${c.name}  ·  ${c.memberCount}", color = Color.White) },
                    onClick = { HavenNet.setActiveCircle(c.id); menu = false },
                )
            }
            androidx.compose.material3.HorizontalDivider(color = HavenTheme.cardBorder)
            val locked = com.blaineam.haven.core.CircleLock.isLocked(activeId)
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(if (locked) "🔓 Unlock this circle" else "🔒 Lock this circle", color = Color.White) },
                onClick = { com.blaineam.haven.core.CircleLock.setLocked(activeId, !locked); menu = false },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("+ New circle", color = HavenTheme.pink) },
                onClick = { menu = false; showCreate = true },
            )
        }
    }
    if (showCreate) {
        var nm by remember { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showCreate = false }, containerColor = HavenTheme.card,
            title = { Text("New circle", color = Color.White) },
            text = {
                OutlinedTextField(value = nm, onValueChange = { nm = it }, singleLine = true,
                    placeholder = { Text("Circle name") },
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink))
            },
            confirmButton = {
                androidx.compose.material3.TextButton(enabled = nm.isNotBlank(),
                    onClick = { HavenNet.createCircle(nm.trim()); showCreate = false }) {
                    Text("Create", color = HavenTheme.pink)
                }
            },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { showCreate = false }) { Text("Cancel", color = HavenTheme.textSecondary) } },
        )
    }
}

/** Live connection status: online (iroh) + relay (mailbox) dots, like the iOS connection chips. */
@Composable
private fun ConnectionDot() {
    val online by HavenNet.internetActive
    val started by HavenNet.started
    val relay by HavenNet.relayActive
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(end = 8.dp)) {
        // The node being up == connected to the iroh network; "Connecting" only during startup.
        val color = if (started) Color(0xFF34D399) else Color(0xFFF59E0B)
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(if (started) (if (online || relay) "Connected" else "Online") else "Connecting",
            color = HavenTheme.textSecondary, fontSize = 11.sp)
        if (relay) Text("· Relay", color = Color(0xFF34D399), fontSize = 11.sp)
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PostCard(item: FeedItemFfi, circleId: String = DEFAULT_CIRCLE) {
    var showComment by remember(item.id) { mutableStateOf(false) }
    var commentDraft by remember(item.id) { mutableStateOf("") }
    var showPicker by remember(item.id) { mutableStateOf(false) }
    var showEdit by remember(item.id) { mutableStateOf(false) }
    var whoReacted by remember(item.id) { mutableStateOf<uniffi.haven_ffi.ReactionFfi?>(null) }
    var viewerStart by remember(item.id) { mutableStateOf<Int?>(null) }
    var commentPicker by remember(item.id) { mutableStateOf<String?>(null) }   // comment id being reacted to
    viewerStart?.let { start ->
        FullScreenOverlay(onDismiss = { viewerStart = null }) {
            MediaViewer(circleId, item.media, start) { viewerStart = null }
        }
    }

    whoReacted?.let { r ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { whoReacted = null }, containerColor = HavenTheme.card,
            title = { Text("${r.emoji}  ${r.count}", color = Color.White) },
            text = {
                Column {
                    r.authors.forEach { a ->
                        Text(if (a.startsWith(HavenNet.nodeIdHex.take(8))) "You" else HavenNet.displayName(a.take(8)),
                            color = Color.White, fontSize = 14.sp, modifier = Modifier.padding(vertical = 2.dp))
                    }
                }
            },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { whoReacted = null }) { Text("Done", color = HavenTheme.pink) } },
        )
    }

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HavenAvatar(item.authorShort, if (item.isMe) "You" else HavenNet.displayName(item.authorShort),
                34.dp, isMe = item.isMe)
            Spacer(Modifier.size(10.dp))
            Text(
                if (item.isMe) "You" else HavenNet.displayName(item.authorShort),
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                relativeTime(item.createdAt) + if (item.edited) " · edited" else "",
                color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp,
            )
        }
        if (item.body.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            LinkedText(item.body, color = Color.White, fontSize = 15.sp)
            LinkPreviewCard(item.body, Modifier.padding(top = 10.dp))
        }

        // Attached photos / videos — gallery with tap-to-open full-screen viewer.
        if (item.media.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            MediaGallery(circleId, item.media) { viewerStart = it }
        }

        // Attached song — artwork + 30s preview playback, resolved via iTunes Search.
        item.music?.let { m ->
            Spacer(Modifier.height(10.dp))
            MusicChip(m)
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
                            .combinedClickable(
                                onClick = {
                                    if (mine) HavenNet.unreact(circleId, item.id, r.emoji)
                                    else HavenNet.react(circleId, item.id, r.emoji)
                                },
                                onLongClick = { whoReacted = r },
                            )
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
            if (item.isMe) {
                Spacer(Modifier.size(8.dp))
                Text("Edit", color = HavenTheme.textSecondary, fontSize = 13.sp,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showEdit = !showEdit }.padding(6.dp))
                Text("Delete", color = Color(0xFFF87171), fontSize = 13.sp,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.unsendPost(circleId, item.id) }.padding(6.dp))
            }
        }
        if (showEdit) {
            var editText by remember(item.id) { mutableStateOf(item.body) }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(value = editText, onValueChange = { editText = it },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink))
                Text("Save", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                        HavenNet.editPost(circleId, item.id, editText.trim()); showEdit = false
                    }.padding(10.dp))
            }
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
                Column(Modifier.padding(vertical = 2.dp)) {
                    // Tap-and-hold a comment to react to it (parity with iOS).
                    Row(Modifier.combinedClickable(onClick = {},
                        onLongClick = { commentPicker = if (commentPicker == c.id) null else c.id })) {
                        Text(if (c.isMe) "You: " else "${HavenNet.displayName(c.authorShort)}: ",
                            color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Text(c.body, color = Color.White, fontSize = 13.sp)
                    }
                    if (c.reactions.isNotEmpty()) {
                        Row(Modifier.padding(start = 4.dp, top = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            c.reactions.forEach { r ->
                                Box(Modifier.clip(RoundedCornerShape(16.dp))
                                    .background(if (r.mine) HavenTheme.pink.copy(alpha = 0.25f) else HavenTheme.background)
                                    .clickable {
                                        if (r.mine) HavenNet.unreact(circleId, c.id, r.emoji) else HavenNet.react(circleId, c.id, r.emoji)
                                    }.padding(horizontal = 8.dp, vertical = 3.dp)) {
                                    Text("${r.emoji} ${r.count}", fontSize = 12.sp, color = Color.White)
                                }
                            }
                        }
                    }
                    if (commentPicker == c.id) {
                        Row(Modifier.padding(top = 2.dp)) {
                            QUICK_EMOJI.forEach { e ->
                                Box(Modifier.clip(CircleShape).clickable {
                                    HavenNet.react(circleId, c.id, e); commentPicker = null
                                }.padding(5.dp)) { Text(e, fontSize = 20.sp) }
                            }
                        }
                    }
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

/** Compact relative timestamp for the feed (now / 5m / 3h / 2d / 1w), like the iOS feed. */
private fun relativeTime(createdAtMs: kotlin.ULong): String {
    val diff = System.currentTimeMillis() - createdAtMs.toLong()
    if (diff < 0) return "now"
    val s = diff / 1000
    return when {
        s < 45 -> "now"
        s < 3600 -> "${s / 60}m"
        s < 86_400 -> "${s / 3600}h"
        s < 604_800 -> "${s / 86_400}d"
        else -> "${s / 604_800}w"
    }
}
