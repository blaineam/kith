package com.blaineam.haven.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.startOver

/** Settings (the ⚙️ behind You): retention, blocked people, start over. Parity with iOS SettingsView. */
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }
    var retention by remember { mutableIntStateOf(profile.retentionDays) }
    var confirmReset by remember { mutableStateOf(false) }

    val options = listOf(0 to "Keep forever", 7 to "After 1 week", 30 to "After 1 month", 90 to "After 3 months", 365 to "After 1 year")

    HavenBackground {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onBack() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
                }
                Spacer(Modifier.size(6.dp))
                BrandText("Settings", fontSize = 24)
            }

            Spacer(Modifier.height(20.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Auto-delete posts", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Old posts disappear on their own — locally and for everyone you share with.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(10.dp))
                options.forEach { (days, label) ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .clickable { retention = days; profile.setRetention(days) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(18.dp).clip(CircleShape)
                            .androidxRing(retention == days), contentAlignment = Alignment.Center) {
                            if (retention == days) Box(Modifier.size(10.dp).clip(CircleShape)
                                .androidxFill())
                        }
                        Spacer(Modifier.size(12.dp))
                        Text(label, color = Color.White, fontSize = 15.sp)
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Blocked people", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(6.dp))
                if (HavenNet.blocked.isEmpty()) {
                    Text("No one blocked.", color = HavenTheme.textSecondary, fontSize = 13.sp)
                } else {
                    HavenNet.blocked.forEach { idHex ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(idHex.take(16) + "…", color = Color.White, fontSize = 13.sp)
                            Spacer(Modifier.size(8.dp))
                            Text("Unblock", color = HavenTheme.pink, fontSize = 13.sp,
                                modifier = Modifier.clickable { HavenNet.unblock(idHex) })
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
            Text("Start over (new identity)", color = Color(0xFFF87171), fontWeight = FontWeight.Medium,
                fontSize = 15.sp, modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { confirmReset = true }.padding(8.dp))
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            containerColor = HavenTheme.card,
            title = { Text("Start over?", color = Color.White) },
            text = {
                Text("This permanently erases your identity, your whole circle, and every post on this device. The people you've connected with will no longer recognize you. This can't be undone.",
                    color = HavenTheme.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { startOver(context) }) {
                    Text("Erase everything", color = Color(0xFFF87171))
                }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel", color = HavenTheme.pink) } },
        )
    }
}

private fun Modifier.androidxRing(on: Boolean): Modifier =
    this.border(2.dp, if (on) HavenTheme.pink else HavenTheme.textSecondary, CircleShape)

private fun Modifier.androidxFill(): Modifier = this.background(HavenTheme.pink)
