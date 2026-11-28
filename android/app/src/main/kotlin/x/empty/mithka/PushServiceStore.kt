package x.empty.mithka

import android.content.Context
import android.content.SharedPreferences

/**
 * Persisted push configuration shared by the Dart bridge, the keep-alive
 * service and the UnifiedPush listener.
 *
 * The values live in their own preference file because the Services can start
 * a cold process before Flutter exists, and because the Dart prefs file is
 * owned by the Flutter engine (which may not be up yet).
 */
object PushServiceStore {
    const val MODE_IN_APP = 0
    const val MODE_FCM = 1
    const val MODE_UNIFIED = 2
    const val MODE_MICROG = 3

    const val DEFAULT_GATEWAY = "https://p2p.belloworld.it/"

    private const val PREFS = "mithka_push"
    private const val KEY_MODE = "mode"
    private const val KEY_GATEWAY = "gateway"
    private const val KEY_RESIDENT = "resident"
    private const val KEY_KEEPALIVE_FALLBACK = "keepalive_fallback"
    private const val KEY_PENDING_TAP = "pending_tap"

    fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun mode(context: Context): Int = prefs(context).getInt(KEY_MODE, MODE_FCM)

    fun setMode(context: Context, mode: Int) {
        prefs(context).edit().putInt(KEY_MODE, mode).apply()
    }

    fun gateway(context: Context): String =
        prefs(context).getString(KEY_GATEWAY, DEFAULT_GATEWAY) ?: DEFAULT_GATEWAY

    fun setGateway(context: Context, gateway: String) {
        prefs(context).edit().putString(KEY_GATEWAY, gateway).apply()
    }

    fun resident(context: Context): Boolean =
        prefs(context).getBoolean(KEY_RESIDENT, false)

    fun setResident(context: Context, resident: Boolean) {
        prefs(context).edit().putBoolean(KEY_RESIDENT, resident).apply()
    }

    fun keepAliveFallback(context: Context): Boolean =
        prefs(context).getBoolean(KEY_KEEPALIVE_FALLBACK, false)

    fun setKeepAliveFallback(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_KEEPALIVE_FALLBACK, enabled).apply()
    }

    fun keepAliveEnabled(context: Context): Boolean =
        mode(context) == MODE_IN_APP || keepAliveFallback(context)

    /** A notification tap captured before Dart was ready to consume it. */
    fun takePendingTap(context: Context): String? {
        val preferences = prefs(context)
        val value = preferences.getString(KEY_PENDING_TAP, null)
        if (value != null) {
            preferences.edit().remove(KEY_PENDING_TAP).apply()
        }
        return value
    }

    fun setPendingTap(context: Context, payload: String) {
        prefs(context).edit().putString(KEY_PENDING_TAP, payload).apply()
    }
}
