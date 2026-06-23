package com.blaineam.haven.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.TextUnit

private val URL_REGEX = Regex("""(https?://[^\s]+)""")

/** Open a URL inside Haven via Chrome Custom Tabs, falling back to the system browser. */
fun openInApp(context: Context, url: String) {
    val uri = Uri.parse(if (url.startsWith("http")) url else "https://$url")
    runCatching { CustomTabsIntent.Builder().build().launchUrl(context, uri) }
        .onFailure { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) } }
}

/** Open a URL externally (ACTION_VIEW) so an installed provider app (Spotify/YouTube/Music) catches it. */
fun openExternal(context: Context, url: String) {
    val uri = Uri.parse(if (url.startsWith("http")) url else "https://$url")
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        .onFailure { openInApp(context, url) }
}

/**
 * Renders body text with tappable links (http/https) that open in the in-app browser — parity with
 * iOS link rendering. Plain text otherwise. YouTube and any other URLs are just links.
 */
@Composable
fun LinkedText(text: String, color: Color, fontSize: TextUnit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    if (!URL_REGEX.containsMatchIn(text)) {
        Text(text, color = color, fontSize = fontSize, modifier = modifier)
        return
    }
    val annotated = buildAnnotatedString {
        var last = 0
        for (m in URL_REGEX.findAll(text)) {
            if (m.range.first > last) append(text.substring(last, m.range.first))
            withLink(
                LinkAnnotation.Url(
                    m.value,
                    TextLinkStyles(SpanStyle(color = HavenTheme.pink, textDecoration = TextDecoration.Underline)),
                ) { openInApp(context, m.value) },
            ) { append(m.value) }
            last = m.range.last + 1
        }
        if (last < text.length) append(text.substring(last))
    }
    Text(annotated, color = color, fontSize = fontSize, modifier = modifier)
}
