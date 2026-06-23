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
                Text("Circle relay", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(
                    if (HavenNet.hasRelay()) "Using a circle relay — posts deliver even when you're not both online."
                    else "Paste a relay node id (from your Mac/iPhone or a haven-relay daemon) so posts deliver when peers are offline.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp,
                )

                // Host the relay on THIS device.
                Spacer(Modifier.height(12.dp))
                val hosting by HavenNet.hosting
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Run the relay on this phone", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        Text("This device serves the circle's mailbox so everyone stays in sync — no cloud.",
                            color = HavenTheme.textSecondary, fontSize = 11.sp)
                    }
                    androidx.compose.material3.Switch(
                        checked = hosting,
                        onCheckedChange = { on -> if (on) HavenNet.startHosting() else HavenNet.stopHosting() },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
                    )
                }
                Spacer(Modifier.height(8.dp))
                Spacer(Modifier.height(10.dp))
                var relayInput by remember { mutableStateOf("") }
                androidx.compose.material3.OutlinedTextField(
                    value = relayInput, onValueChange = { relayInput = it.trim() },
                    label = { Text("Relay node id (64 hex)") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
                )
                Spacer(Modifier.height(8.dp))
                Text("Use this relay", color = if (relayInput.length == 64) HavenTheme.pink else HavenTheme.textSecondary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = relayInput.length == 64) {
                        HavenNet.adoptRelay(relayInput); relayInput = ""
                    }.padding(8.dp))
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
