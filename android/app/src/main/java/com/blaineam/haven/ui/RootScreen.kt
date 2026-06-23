package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

private enum class Tab(val label: String, val icon: ImageVector) {
    Circle("Circle", Icons.Filled.AutoAwesome),
    Messages("Messages", Icons.Filled.Forum),
    You("You", Icons.Filled.Person),
}

/** Top-level: onboarding gates the app, then the 3-tab scaffold (parity with iOS RootView). */
@Composable
fun RootScreen() {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }

    Crossfade(targetState = profile.onboarded, label = "root") { onboarded ->
        if (!onboarded) {
            OnboardingScreen { name, emoji ->
                HavenCore.get(context)           // generate + persist identity on first run
                profile.completeOnboarding(name, emoji)
            }
        } else {
            MainScaffold()
        }
    }
}

@Composable
private fun MainScaffold() {
    val context = LocalContext.current
    var tab by remember { mutableStateOf(Tab.Circle) }
    var showConnect by remember { mutableStateOf(false) }

    // Bring the transport up once we're past onboarding; re-sync on resume.
    LaunchedEffect(Unit) {
        HavenNet.init(context)
        HavenNet.start()
        com.blaineam.haven.core.CallManager.init(context, HavenNet.nodeIdHex)
    }
    // Notification permission on Android 13+ (no-op below).
    val notifPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) {
        if (android.os.Build.VERSION.SDK_INT >= 33) notifPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    HavenNet.isForeground = true; HavenNet.syncWithContacts(); HavenNet.requestMissingMedia()
                }
                Lifecycle.Event.ON_PAUSE -> HavenNet.isForeground = false
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }

    Scaffold(
        containerColor = HavenTheme.background,
        bottomBar = {
            NavigationBar(containerColor = HavenTheme.card) {
                Tab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = { Icon(t.icon, contentDescription = t.label) },
                        label = { Text(t.label) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = HavenTheme.pink,
                            selectedTextColor = HavenTheme.pink,
                            indicatorColor = HavenTheme.pink.copy(alpha = 0.14f),
                            unselectedIconColor = HavenTheme.textSecondary,
                            unselectedTextColor = HavenTheme.textSecondary,
                        ),
                    )
                }
            }
        },
    ) { inner ->
        Box(Modifier.fillMaxSize().padding(inner)) {
            when (tab) {
                Tab.Circle -> CircleScreen(onAddFriend = { showConnect = true })
                Tab.Messages -> MessagesScreen()
                Tab.You -> YouScreen(onAddFriend = { showConnect = true })
            }
        }
    }

    // Connect sheet (full-screen slide-up).
    AnimatedVisibility(
        visible = showConnect,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        ConnectScreen(onDone = { showConnect = false })
    }

    // Call overlay (incoming ring / in-call mesh grid) sits above everything.
    CallOverlay()
}
