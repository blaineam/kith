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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Videocam
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
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.HavenNet

/** Messages tab — a list of people to DM, then a chat thread. DM = private 2-person circle. */
@Composable
fun MessagesScreen() {
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
private fun DmThread(circleId: String, partner: Contact, onBack: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    val version by HavenNet.feedVersion
    val msgs = remember(version, circleId) { HavenNet.messages(circleId) }

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
                items(msgs, key = { it.id }) { m -> Bubble(m.body, mine = m.isMe) }
            }

            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft, onValueChange = { draft = it },
                    placeholder = { Text("Message…") },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(22.dp), maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Spacer(Modifier.size(8.dp))
                Box(
                    Modifier.size(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
                        .clickable(enabled = draft.isNotBlank()) {
                            HavenNet.sendDm(circleId, draft.trim()); draft = ""
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color.White) }
            }
        }
    }
}

@Composable
private fun Bubble(text: String, mine: Boolean) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Box(
            Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(18.dp))
                .background(if (mine) HavenTheme.pink else HavenTheme.card)
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) { Text(text, color = Color.White, fontSize = 15.sp) }
    }
}
