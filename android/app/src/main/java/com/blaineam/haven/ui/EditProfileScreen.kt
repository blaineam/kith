package com.blaineam.haven.ui

import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

/** Edit your business card — name, emoji, bio (parity with the iOS EditProfileSheet). */
@Composable
fun EditProfileScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }
    var name by remember { mutableStateOf(profile.displayName) }
    var bio by remember { mutableStateOf(profile.bio) }
    var emoji by remember { mutableStateOf(profile.emoji) }
    val emojis = listOf("🌅", "🌙", "⭐️", "🔥", "🌊", "🌸", "🦊", "🐦", "🍃", "💜", "🐺", "🎧")

    HavenBackground {
        Column(Modifier.fillMaxSize().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onDone() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
                }
                Spacer(Modifier.size(6.dp))
                BrandText("Edit profile", fontSize = 24)
            }
            Spacer(Modifier.height(20.dp))

            Text("Your face", color = HavenTheme.textSecondary, fontSize = 13.sp)
            Spacer(Modifier.height(8.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(emojis.size) { i ->
                    val e = emojis[i]
                    Box(
                        Modifier.size(48.dp).border(
                            width = if (e == emoji) 2.dp else 0.dp,
                            color = if (e == emoji) HavenTheme.pink else Color.Transparent,
                            shape = CircleShape,
                        ).clickable { emoji = e },
                        contentAlignment = Alignment.Center,
                    ) { Text(e, fontSize = 26.sp) }
                }
            }

            Spacer(Modifier.height(18.dp))
            OutlinedTextField(
                value = name, onValueChange = { name = it }, label = { Text("Name") },
                singleLine = true, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = bio, onValueChange = { bio = it }, label = { Text("Bio") },
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), maxLines = 3,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
            )

            Spacer(Modifier.height(24.dp))
            BrandButton(text = "Save", enabled = name.isNotBlank()) {
                profile.displayName = name.trim()
                profile.bio = bio.trim()
                profile.emoji = emoji
                profile.save()
                HavenNet.syncWithContacts()   // re-share the updated business card
                onDone()
            }
        }
    }
}
