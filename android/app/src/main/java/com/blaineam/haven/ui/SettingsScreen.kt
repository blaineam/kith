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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.size
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
    var showTransfer by remember { mutableStateOf(false) }
    var showRestore by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<uniffi.haven_ffi.SelfTestReport?>(null) }
    val core = remember { com.blaineam.haven.core.HavenCore.get(context) }

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
                Text("Photos", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Keep a copy in your gallery (Pictures/Haven).", color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                SettingSwitch("Save my posts to Photos", profile.saveMyPosts) { profile.saveMyPosts = it }
                SettingSwitch("Save others' posts to Photos", profile.saveOthersPosts) { profile.saveOthersPosts = it }
                SettingSwitch("Auto-optimize media (smaller, faster)", profile.autoOptimize) { profile.autoOptimize = it }
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

                // Adopted relays, with reachability + remove. Posts mirror to ALL of these and read
                // falls back across them, so adding several gives graceful redundancy.
                val relaysVersion by HavenNet.relaysVersion
                val relays = remember(relaysVersion) { HavenNet.relaysDetail() }
                if (relays.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text("Relays (${relays.size})", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    relays.forEach { (hex, reachable, hosted) ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(
                                if (reachable) Color(0xFF34C759) else Color(0xFFFF9500)))
                            Spacer(Modifier.size(8.dp))
                            Column(Modifier.weight(1f)) {
                                Text(hex.take(16) + "…", color = Color.White, fontSize = 13.sp)
                                Text(
                                    when {
                                        hosted -> "Hosted on this phone"
                                        reachable -> "Reachable"
                                        else -> "Unreachable — backing off"
                                    },
                                    color = HavenTheme.textSecondary, fontSize = 11.sp,
                                )
                            }
                            if (!hosted) {
                                Text("Remove", color = HavenTheme.textSecondary, fontSize = 12.sp,
                                    modifier = Modifier.clip(RoundedCornerShape(8.dp))
                                        .clickable { HavenNet.forgetRelay(hex) }.padding(6.dp))
                            }
                        }
                    }
                }

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
                Text("Add this relay", color = if (relayInput.length == 64) HavenTheme.pink else HavenTheme.textSecondary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = relayInput.length == 64) {
                        HavenNet.adoptRelay(relayInput); relayInput = ""
                    }.padding(8.dp))
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Stay connected", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Keep Haven connected in the background for instant posts, messages and calls — no server, no Google. Uses a little battery and shows an ongoing notification.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var stayOn by remember { mutableStateOf(com.blaineam.haven.core.ConnectionService.isEnabled(context)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Real-time connection", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = stayOn,
                        onCheckedChange = { on -> com.blaineam.haven.core.ConnectionService.setEnabled(context, on); stayOn = on },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Nearby (offline)", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Share with people right next to you over Bluetooth/Wi-Fi — no internet needed.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var nearbyOn by remember { mutableStateOf(HavenNet.nearbyWanted()) }
                val nearbyPerms = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()) { grants ->
                    if (grants.values.all { it }) { HavenNet.enableNearby(); nearbyOn = true }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Nearby sharing", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = nearbyOn,
                        onCheckedChange = { on ->
                            if (on) {
                                val perms = if (android.os.Build.VERSION.SDK_INT >= 33)
                                    arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT,
                                        android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.NEARBY_WIFI_DEVICES)
                                else arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
                                nearbyPerms.launch(perms)
                            } else { HavenNet.disableNearby(); nearbyOn = false }
                        },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
                    )
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

            // Under the hood (identity hex + safety words + crypto) — nested here, like iOS.
            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Under the hood", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Your id", color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(core.nodeIdHex.take(24) + "…", color = Color.White, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(6.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Safety words", color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(com.blaineam.haven.core.SafetyWords.phrase(core.verificationHex), color = Color.White, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(10.dp))
                Text("Haven uses hybrid post-quantum encryption (X25519 + ML-KEM-768, Ed25519 + ML-DSA). Your keys never leave this device.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                BrandButton(text = "Run privacy check") { report = core.runSelfTest() }
                report?.let { r ->
                    Spacer(Modifier.height(14.dp))
                    SettingsCheck("Identity is yours", r.identityOk)
                    SettingsCheck("Your stuff is locked (seal → open)", r.hybridKemOk)
                    SettingsCheck("Messages are signed", r.signatureOk)
                    SettingsCheck("Invite links are safe", r.linkOk)
                    Spacer(Modifier.height(8.dp))
                    Text(r.summary, color = if (r.allOk) Color(0xFF34D399) else Color(0xFFF87171),
                        fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                }
            }

            // Identity — move to another device / restore here.
            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Your identity", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Move your account to a new phone, or restore it here. Your keys never touch a server.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(10.dp))
                Text("Move to another device →", color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showTransfer = true }.padding(vertical = 8.dp))
                Text("Restore identity here →", color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showRestore = true }.padding(vertical = 8.dp))
            }

            Spacer(Modifier.height(24.dp))
            Text("Start over (new identity)", color = Color(0xFFF87171), fontWeight = FontWeight.Medium,
                fontSize = 15.sp, modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { confirmReset = true }.padding(8.dp))
        }
    }

    // Transfer: show this identity's seed QR for the new device to scan.
    if (showTransfer) {
        FullScreenOverlay(onDismiss = { showTransfer = false }) {
            val core = remember { com.blaineam.haven.core.HavenCore.get(context) }
            val qr = rememberQr(core.exportSeedUri())
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Done", color = HavenTheme.textSecondary, modifier = Modifier.align(Alignment.End).clickable { showTransfer = false }.padding(8.dp))
                Spacer(Modifier.height(12.dp))
                BrandText("Move to another device", fontSize = 22)
                Spacer(Modifier.height(8.dp))
                Text("On your other phone: Settings → Restore identity here → scan this. Keep it private — anyone who scans it becomes you.",
                    color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(20.dp))
                qr?.let { androidx.compose.foundation.Image(it, "Identity transfer QR",
                    Modifier.size(260.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF101018)).padding(8.dp)) }
            }
        }
    }
    // Restore: scan a seed QR from another device, adopt it, restart clean.
    if (showRestore) {
        FullScreenOverlay(onDismiss = { showRestore = false }) {
            QrScannerScreen(
                onResult = { text ->
                    showRestore = false
                    if (text.startsWith("haven-seed:") && com.blaineam.haven.core.HavenCore.get(context).importSeed(text)) {
                        HavenNet.reset()
                        com.blaineam.haven.core.restartApp(context)
                    }
                },
                onCancel = { showRestore = false },
            )
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

@Composable
private fun SettingsCheck(title: String, ok: Boolean) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(if (ok) "✓" else "✗", color = if (ok) Color(0xFF34D399) else Color(0xFFF87171),
            fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.size(10.dp))
        Text(title, color = Color.White, fontSize = 14.sp)
    }
}

@Composable
private fun SettingSwitch(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
        androidx.compose.material3.Switch(checked = checked, onCheckedChange = onChange,
            colors = androidx.compose.material3.SwitchDefaults.colors(
                checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink))
    }
}
