package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.blaineam.haven.core.CallManager
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * Renders one WebRTC video track in a SurfaceViewRenderer it owns, attaching/detaching the sink
 * across recomposition so tracks bind reliably.
 */
@Composable
fun CallVideoTile(track: VideoTrack?, modifier: Modifier = Modifier, mirror: Boolean = false) {
    val context = LocalContext.current
    val view = remember {
        SurfaceViewRenderer(context).apply {
            init(CallManager.eglBase.eglBaseContext, null)
            setEnableHardwareScaler(true)
            setMirror(mirror)
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
        }
    }
    AndroidView(factory = { view }, modifier = modifier)
    DisposableEffect(track) {
        track?.addSink(view)
        onDispose { runCatching { track?.removeSink(view) } }
    }
    DisposableEffect(Unit) { onDispose { runCatching { view.release() } } }
}

/** Returns a launcher that requests camera+mic, then starts a call to the given participants. */
@Composable
fun rememberCallStarter(): (List<String>, String) -> Unit {
    val pending = remember { androidx.compose.runtime.mutableStateOf<Pair<List<String>, String>?>(null) }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        if (grants.values.all { it }) pending.value?.let { (o, n) -> CallManager.startCall(o, n) }
        pending.value = null
    }
    return { others, name ->
        pending.value = others to name
        launcher.launch(arrayOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO))
    }
}

/** The call overlay: incoming ring, or the in-call mesh grid. Mounted at the app root. */
@Composable
fun CallOverlay() {
    val ringing by CallManager.ringing
    val inCall by CallManager.inCall
    val connecting by CallManager.connecting

    when {
        ringing && !inCall -> IncomingCall()
        inCall || connecting -> InCall()
    }
}

@Composable
private fun IncomingCall() {
    val name by CallManager.peerName
    Box(Modifier.fillMaxSize().background(Color(0xF2000000)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            ConstellationMark(Modifier.size(72.dp))
            Spacer(Modifier.height(20.dp))
            Text(name.ifBlank { "Incoming call" }, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(4.dp))
            Text("Haven call", color = HavenTheme.textSecondary, fontSize = 14.sp)
            Spacer(Modifier.height(48.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                RoundButton(Icons.Filled.CallEnd, Color(0xFFEF4444), "Decline") { CallManager.decline() }
                RoundButton(Icons.Filled.Videocam, Color(0xFF22C55E), "Accept") { CallManager.accept() }
            }
        }
    }
}

@Composable
private fun InCall() {
    val name by CallManager.peerName
    val micOn by CallManager.micOn
    val cameraOn by CallManager.cameraOn
    val participants = CallManager.participants
    val remote = CallManager.remoteVideo

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // Remote tiles in a grid; local preview pinned bottom-right.
        if (participants.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Connecting…", color = Color.White, fontSize = 18.sp)
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(if (participants.size <= 1) 1 else 2),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(participants, key = { it }) { hex ->
                    Box(Modifier.padding(2.dp).aspectRatio(0.75f).background(HavenTheme.card)) {
                        CallVideoTile(remote[hex], Modifier.fillMaxSize())
                        Text(hex.take(6), color = Color.White, fontSize = 11.sp,
                            modifier = Modifier.align(Alignment.BottomStart).padding(6.dp))
                    }
                }
            }
        }

        // Local self-preview.
        Box(
            Modifier.align(Alignment.TopEnd).padding(12.dp).size(96.dp, 132.dp)
                .clip(RoundedCornerShape(12.dp)).background(HavenTheme.card),
        ) { CallVideoTile(CallManager.localVideo, Modifier.fillMaxSize(), mirror = true) }

        // Title.
        Text(name.ifBlank { "Haven call" }, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.TopStart).padding(16.dp))

        // Controls.
        Row(
            Modifier.align(Alignment.BottomCenter).padding(bottom = 36.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            RoundButton(if (micOn) Icons.Filled.Mic else Icons.Filled.MicOff,
                if (micOn) HavenTheme.card else Color.White, "Mic") { CallManager.toggleMic() }
            RoundButton(if (cameraOn) Icons.Filled.Videocam else Icons.Filled.VideocamOff,
                if (cameraOn) HavenTheme.card else Color.White, "Camera") { CallManager.toggleCamera() }
            RoundButton(Icons.Filled.Cameraswitch, HavenTheme.card, "Flip") { CallManager.switchCamera() }
            RoundButton(Icons.Filled.CallEnd, Color(0xFFEF4444), "End") { CallManager.hangup() }
        }
    }
}

@Composable
private fun RoundButton(icon: ImageVector, bg: Color, desc: String, onClick: () -> Unit) {
    Box(
        Modifier.size(60.dp).clip(CircleShape).background(bg).clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, desc, tint = if (bg == HavenTheme.card) Color.White else Color.Black, modifier = Modifier.size(26.dp)) }
}
