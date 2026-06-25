package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.TextButton
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
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.HavenNet

/** Messages tab — a list of people to DM, then a chat thread. DM = private 2-person circle. */
@Composable
fun MessagesScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lockV by com.blaineam.haven.core.CircleLock.version
    if (remember(lockV) { com.blaineam.haven.core.CircleLock.needsUnlock(com.blaineam.haven.core.DEFAULT_CIRCLE) }) {
        HavenBackground {
            Column(Modifier.fillMaxSize().padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text("🔒", fontSize = 48.sp)
                Spacer(Modifier.height(12.dp))
                Text("Messages are locked", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(6.dp))
                Text("Unlock your circle to see your private chats.", color = HavenTheme.textSecondary,
                    fontSize = 13.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                BrandButton(text = "Unlock", modifier = Modifier.fillMaxWidth(0.6f)) {
                    (context as? androidx.fragment.app.FragmentActivity)?.let {
                        com.blaineam.haven.core.CircleLock.authenticate(it, com.blaineam.haven.core.DEFAULT_CIRCLE) {}
                    }
                }
            }
        }
        return
    }
    var openThread by remember { mutableStateOf<Pair<String, Contact>?>(null) }

    val thread = openThread
    if (thread == null) {
        ThreadList(onOpen = { c -> openThread = HavenNet.startDm(c) to c })
    } else {
        DmThread(circleId = thread.first, partner = thread.second, onBack = { openThread = null })
    }
}

@Composable
private fun ThreadList(onOpen: (Contact) -> Unit) {
    val contacts = HavenNet.contacts
    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            BrandText("Messages", fontSize = 26,
                modifier = Modifier.padding(start = 20.dp, top = 16.dp, bottom = 8.dp).align(Alignment.Start))
            if (contacts.isEmpty()) {
                Column(
                    Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text("No one to message yet", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text("Add a friend from the Circle tab, then DM them here.",
                        color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                }
            } else {
                LazyColumn(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(contacts, key = { it.idHex }) { c ->
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                                .clickable { onOpen(c) }.havenCard().padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(40.dp).clip(CircleShape).background(HavenTheme.brand),
                                contentAlignment = Alignment.Center) {
                                Text(c.name.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold)
                            }
                            Spacer(Modifier.size(12.dp))
                            Text(c.name, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DmThread(circleId: String, partner: Contact, onBack: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var draft by remember { mutableStateOf("") }
    var pendingPhoto by remember { mutableStateOf<String?>(null) }
    var pendingMusic by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var showMusicDialog by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    var secretMode by remember { mutableStateOf(false) }
    var disappearSecs by remember { mutableStateOf<ULong?>(null) }
    var editingId by remember { mutableStateOf<String?>(null) }
    var showOptions by remember { mutableStateOf(false) }
    val version by HavenNet.feedVersion
    val msgs = remember(version, circleId) { HavenNet.messages(circleId) }
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            if (com.blaineam.haven.core.isVideoUri(context, uri)) {
                com.blaineam.haven.core.readVideoBytes(context, uri)?.let { pendingPhoto = com.blaineam.haven.core.LocalMedia.store(circleId, it, isVideo = true) }
            } else {
                com.blaineam.haven.core.loadAndDownscale(context, uri)?.let { pendingPhoto = com.blaineam.haven.core.LocalMedia.store(circleId, it) }
            }
        }
    }

    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 8.dp, end = 16.dp, top = 14.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onBack() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
                }
                Spacer(Modifier.size(4.dp))
                Text(partner.name, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                val startCall = rememberCallStarter()
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    startCall(listOf(partner.idHex), partner.name)
                }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Videocam, "Video call", tint = HavenTheme.pink)
                }
            }

            LazyColumn(
                Modifier.fillMaxWidth().weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(msgs, key = { it.id }) { m ->
                    Bubble(m, circleId = circleId, onEdit = { msg ->
                        editingId = msg.id; secretMode = com.blaineam.haven.core.SecretMessages.isSecret(msg.body)
                        draft = com.blaineam.haven.core.SecretMessages.text(msg.body)
                    })
                }
            }

            pendingPhoto?.let { ref ->
                Box(Modifier.padding(start = 16.dp, bottom = 4.dp)) {
                    if (com.blaineam.haven.core.LocalMedia.isVideo(ref))
                        Box(Modifier.size(56.dp).clip(RoundedCornerShape(10.dp)).background(HavenTheme.card),
                            contentAlignment = Alignment.Center) { Icon(Icons.Filled.Videocam, null, tint = Color.White) }
                    else MediaImage(circleId, ref, Modifier.size(56.dp).clip(RoundedCornerShape(10.dp)))
                }
            }
            pendingMusic?.let { m ->
                Row(Modifier.padding(start = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    MusicChip(m)
                    Icon(Icons.Filled.Close, "Remove song", tint = Color.White,
                        modifier = Modifier.padding(start = 6.dp).size(18.dp).clickable { pendingMusic = null })
                }
            }
            if (editingId != null) {
                Row(Modifier.padding(start = 16.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Editing message", color = HavenTheme.pink, fontSize = 12.sp)
                    Spacer(Modifier.size(10.dp))
                    Text("Cancel", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp,
                        modifier = Modifier.clickable { editingId = null; draft = ""; secretMode = false })
                }
            }

            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    picker.launch(androidx.activity.result.PickVisualMediaRequest(
                        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.AddPhotoAlternate, "Photo", tint = HavenTheme.pink)
                }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { showMusicDialog = true },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.MusicNote, "Add a song", tint = HavenTheme.pink)
                }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { showVoice = true },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Mic, "Voice message", tint = HavenTheme.pink)
                }
                Box(contentAlignment = Alignment.Center) {
                    Box(Modifier.size(40.dp).clip(CircleShape).clickable { showOptions = true },
                        contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.MoreVert, "More options",
                            tint = if (secretMode || disappearSecs != null) HavenTheme.pink else Color.White.copy(alpha = 0.5f))
                    }
                    DropdownMenu(expanded = showOptions, onDismissRequest = { showOptions = false }) {
                        DropdownMenuItem(
                            text = { Text(if (secretMode) "✓ Secret message" else "Secret message") },
                            onClick = { secretMode = !secretMode; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == null) "✓ Don't disappear" else "Don't disappear") },
                            onClick = { disappearSecs = null; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 3_600UL) "✓ Disappear · 1 hour" else "Disappear · 1 hour") },
                            onClick = { disappearSecs = 3_600UL; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 86_400UL) "✓ Disappear · 1 day" else "Disappear · 1 day") },
                            onClick = { disappearSecs = 86_400UL; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 604_800UL) "✓ Disappear · 1 week" else "Disappear · 1 week") },
                            onClick = { disappearSecs = 604_800UL; showOptions = false })
                    }
                }
                OutlinedTextField(
                    value = draft, onValueChange = { draft = it },
                    placeholder = { Text("Message…") },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(22.dp), maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Spacer(Modifier.size(8.dp))
                val canSend = draft.isNotBlank() || pendingPhoto != null || pendingMusic != null
                Box(
                    Modifier.size(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
                        .clickable(enabled = canSend) {
                            val body = if (secretMode && draft.isNotBlank())
                                com.blaineam.haven.core.SecretMessages.encode(draft.trim()) else draft.trim()
                            val eid = editingId
                            if (eid != null) HavenNet.editPost(circleId, eid, body)
                            else HavenNet.sendDm(circleId, body, listOfNotNull(pendingPhoto), pendingMusic, disappearSecs)
                            // disappearSecs stays sticky for the conversation (iOS parity); reset the rest.
                            draft = ""; pendingPhoto = null; pendingMusic = null; secretMode = false; editingId = null
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color.White) }
            }
        }
        if (showMusicDialog) {
            MusicSearchSheet(onPick = { pendingMusic = it; showMusicDialog = false }, onDismiss = { showMusicDialog = false })
        }
        if (showVoice) {
            VoiceRecorderDialog(circleId,
                onDone = { ref -> HavenNet.sendDm(circleId, "", listOf(ref)); showVoice = false },
                onDismiss = { showVoice = false })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Bubble(m: uniffi.haven_ffi.FeedItemFfi, circleId: String, onEdit: ((uniffi.haven_ffi.FeedItemFfi) -> Unit)? = null) {
    val mine = m.isMe
    val text = m.body
    var showReact by remember(m.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        Column(
            Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(18.dp))
                .background(if (mine) HavenTheme.pink else HavenTheme.card)
                .combinedClickable(onClick = {}, onLongClick = { showReact = true })
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            m.media.forEach { ref ->
                when {
                    com.blaineam.haven.core.LocalMedia.isAudio(ref) -> AudioPlayerPill(circleId, ref)
                    com.blaineam.haven.core.LocalMedia.isVideo(ref) ->
                        VideoTile(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)))
                    else -> MediaImage(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)))
                }
                if (text.isNotBlank() || m.music != null) Spacer(Modifier.size(6.dp))
            }
            if (text.isNotBlank()) {
                if (com.blaineam.haven.core.SecretMessages.isSecret(text)) SecretBubble(text)
                else LinkedText(text, color = Color.White, fontSize = 15.sp)
            }
            // A shared song renders as the same chip as in the feed.
            m.music?.let { mus ->
                if (text.isNotBlank()) Spacer(Modifier.size(6.dp))
                MusicChip(mus)
            }
        }
        // Reactions on this message — tap one to toggle yours (long-press the bubble to add).
        if (m.reactions.isNotEmpty()) {
            Row(Modifier.padding(top = 3.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                m.reactions.forEach { r ->
                    Box(
                        Modifier.clip(RoundedCornerShape(12.dp)).background(HavenTheme.card)
                            .clickable {
                                if (r.mine) HavenNet.unreact(circleId, m.id, r.emoji)
                                else HavenNet.react(circleId, m.id, r.emoji)
                            }
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    ) { Text("${r.emoji} ${r.count}", fontSize = 12.sp, color = Color.White) }
                }
            }
        }
    }
    if (showReact) {
        AlertDialog(
            onDismissRequest = { showReact = false },
            confirmButton = { TextButton(onClick = { showReact = false }) { Text("Close", color = HavenTheme.pink) } },
            text = {
                Column {
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        listOf("❤️", "😂", "👍", "🎉", "😮", "😢", "🔥").forEach { e ->
                            Text(e, fontSize = 28.sp, modifier = Modifier.clickable {
                                HavenNet.react(circleId, m.id, e); showReact = false
                            })
                        }
                    }
                    // Your own message: edit (text) or delete.
                    if (mine) {
                        Spacer(Modifier.size(14.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            if (text.isNotBlank()) Text("Edit", color = HavenTheme.pink, fontSize = 15.sp,
                                modifier = Modifier.clickable { onEdit?.invoke(m); showReact = false })
                            Text("Delete", color = HavenTheme.pink, fontSize = 15.sp,
                                modifier = Modifier.clickable { HavenNet.unsendPost(circleId, m.id); showReact = false })
                        }
                    }
                }
            },
        )
    }
}
