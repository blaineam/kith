package com.blaineam.haven

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.blaineam.haven.core.ShareInbox
import com.blaineam.haven.ui.HavenAppTheme
import com.blaineam.haven.ui.RootScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handleShare(intent)
        setContent {
            HavenAppTheme {
                RootScreen()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    /** A YouTube/web link (or any text) shared into Haven → prefill the composer. */
    private fun handleShare(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text") == true) {
            ShareInbox.offer(intent.getStringExtra(Intent.EXTRA_TEXT))
        }
    }
}
