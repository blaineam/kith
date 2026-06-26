package com.blaineam.haven.core

import android.content.Context
import android.location.Geocoder
import android.location.LocationManager
import java.util.Locale

/**
 * A shared pinned location, carried inside a post's media array as a `geo:<lat>,<lon>,<label>` ref —
 * byte-for-byte the SAME format as iOS (apple/HavenApp/LocationShare.swift), so it travels with no
 * wire/engine change and renders on either platform. iOS shows an inline map; Android shows a location
 * chip that opens the system maps app.
 */
object LocationShare {
    const val PREFIX = "geo:"

    fun ref(lat: Double, lon: Double, label: String): String =
        // Commas delimit the ref, so strip them from the free-text label (matches iOS).
        "$PREFIX$lat,$lon,${label.replace(",", " ")}"

    fun isLocation(ref: String): Boolean = ref.startsWith(PREFIX)

    data class Pin(val lat: Double, val lon: Double, val label: String)

    fun parse(ref: String): Pin? {
        if (!ref.startsWith(PREFIX)) return null
        val parts = ref.removePrefix(PREFIX).split(",", limit = 3)
        val lat = parts.getOrNull(0)?.toDoubleOrNull() ?: return null
        val lon = parts.getOrNull(1)?.toDoubleOrNull() ?: return null
        return Pin(lat, lon, parts.getOrNull(2)?.takeIf { it.isNotBlank() } ?: "Pinned location")
    }

    /** Best-effort current location → a `geo:` ref with a reverse-geocoded place name; null if unavailable. */
    fun currentRef(context: Context): String? {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        val loc = runCatching {
            lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                ?: lm.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER)
        }.getOrNull() ?: return null
        val label = runCatching {
            @Suppress("DEPRECATION")
            Geocoder(context, Locale.getDefault()).getFromLocation(loc.latitude, loc.longitude, 1)
                ?.firstOrNull()?.let { it.featureName ?: it.locality ?: it.subAdminArea ?: it.adminArea }
        }.getOrNull() ?: "Pinned location"
        return ref(loc.latitude, loc.longitude, label ?: "Pinned location")
    }
}
