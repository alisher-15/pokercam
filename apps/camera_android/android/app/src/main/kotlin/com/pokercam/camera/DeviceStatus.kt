package com.pokercam.camera

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/** Battery, temperature, thermal status and network for device.telemetry and the policies of SPEC 6.4. */
class DeviceStatus(private val context: Context) {
    private val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    fun snapshot(): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val tenthsC = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0
        return mapOf(
            "battery_pct" to if (level >= 0 && scale > 0) level * 100 / scale else 0,
            "charging" to (plugged != 0),
            "temp_c" to tenthsC / 10.0,
            "thermal_status" to thermalStatus(),
            "network" to network(),
        )
    }

    /** PowerManager's thermal status as contracts ThermalStatus (`adb shell cmd thermalservice override-status N` sets it). */
    private fun thermalStatus(): String =
        when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "none"
        }

    private fun network(): Map<String, Any?> {
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return mapOf("type" to "none")
        val type =
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                else -> "wifi"
            }
        val info = mutableMapOf<String, Any?>("type" to type)
        // RSSI for Wi-Fi in dBm; Integer.MIN_VALUE when unknown.
        val strength = caps.signalStrength
        if (type == "wifi" && strength != Int.MIN_VALUE) info["rssi"] = strength
        if (caps.linkUpstreamBandwidthKbps > 0) info["uplink_kbps"] = caps.linkUpstreamBandwidthKbps
        return info
    }

    /** Stable per app signing key and device: the backend keeps only its hash (SPEC 5.1). */
    @SuppressLint("HardwareIds")
    fun androidId(): String = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown"

    fun model(): String =
        listOf(Build.MANUFACTURER, Build.MODEL).filter { it.isNotBlank() }.joinToString(" ").ifBlank { "Android" }

    /** SPEC 6.3: Android must not stop the app to save battery while it streams. */
    fun ignoresBatteryOptimizations(): Boolean = power.isIgnoringBatteryOptimizations(context.packageName)
}
