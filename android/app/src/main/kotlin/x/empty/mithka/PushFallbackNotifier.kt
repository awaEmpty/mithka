package x.empty.mithka

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * A last-resort notification for messages that arrive while the Flutter
 * engine is not attached (the process was started by the UnifiedPush
 * service). TDLib normally turns pushes into notifications in Dart; without
 * an engine we can only show what the payload already contains, and the tap
 * reopens the app so TDLib can sync.
 */
object PushFallbackNotifier {
    private const val CHANNEL_ID = "mithka_push_messages"
    private const val NOTIFICATION_ID_BASE = 0x4D590000
    private val postedIds = mutableSetOf<Int>()

    fun post(context: Context, payload: String?) {
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                app,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(app)
        val parsed = parse(app, payload)
        // MUST be the enabled launcher component, not MainActivity: naming the
        // alias target starts a second Activity (and a second FlutterEngine) in
        // a process that already has one, and TDLib aborts on a second receive
        // thread (Client.cpp:285).
        val intent = AppEntry.intent(app).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            parsed.tapPayload?.let {
                putExtra(PushServiceBridge.EXTRA_TAP_PAYLOAD, it)
            }
        }
        val pendingIntent = PendingIntent.getActivity(
            app,
            (parsed.chatId ?: 0L).hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_push)
            .setContentTitle(parsed.title)
            .setContentText(parsed.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(parsed.body))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .build()
        val id = NOTIFICATION_ID_BASE +
            ((parsed.chatId ?: System.currentTimeMillis()) and 0xFFFFL).toInt()
        try {
            NotificationManagerCompat.from(app).notify(id, notification)
            postedIds.add(id)
        } catch (_: SecurityException) {
        }
    }

    /** Removes fallback notifications once Dart is up and owns the inbox. */
    fun clear(context: Context) {
        val manager = NotificationManagerCompat.from(context.applicationContext)
        for (id in postedIds.toList()) {
            try {
                manager.cancel(id)
            } catch (_: Throwable) {
            }
        }
        postedIds.clear()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.push_fallback_channel),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    private class Parsed(
        val title: String,
        val body: String,
        val chatId: Long?,
        val tapPayload: String?,
    )

    private fun parse(context: Context, payload: String?): Parsed {
        val appName = context.getString(R.string.app_name)
        val fallback = Parsed(
            appName,
            context.getString(R.string.push_fallback_new_message),
            null,
            null,
        )
        if (payload.isNullOrBlank()) return fallback
        val root = try {
            JSONObject(payload)
        } catch (_: Throwable) {
            return fallback
        }
        val custom = root.optJSONObject("custom") ?: JSONObject()
        val locKey = root.optString("loc_key", "")
        val arguments = root.optJSONArray("loc_args")
        val args = buildList {
            if (arguments != null) {
                for (index in 0 until arguments.length()) {
                    add(arguments.optString(index, ""))
                }
            }
        }
        val title = args.firstOrNull()?.takeIf { it.isNotBlank() } ?: appName
        val body = when {
            locKey.contains("TEXT") -> args.lastOrNull()?.takeIf { it.isNotBlank() }
                ?: context.getString(R.string.push_fallback_new_message)
            locKey.contains("PHOTO") -> context.getString(R.string.push_fallback_photo)
            locKey.contains("VIDEO") -> context.getString(R.string.push_fallback_video)
            locKey.contains("VOICE") -> context.getString(R.string.push_fallback_voice)
            locKey.contains("AUDIO") || locKey.contains("MUSIC") ->
                context.getString(R.string.push_fallback_audio)
            locKey.contains("STICKER") -> context.getString(R.string.push_fallback_sticker)
            locKey.contains("GIF") -> context.getString(R.string.push_fallback_gif)
            locKey.contains("FILE") || locKey.contains("DOCUMENT") ->
                context.getString(R.string.push_fallback_file)
            locKey.contains("LOCATION") -> context.getString(R.string.push_fallback_location)
            locKey.contains("CONTACT") -> context.getString(R.string.push_fallback_contact)
            locKey.contains("POLL") -> context.getString(R.string.push_fallback_poll)
            locKey.contains("GIFT") -> context.getString(R.string.push_fallback_gift)
            else -> context.getString(R.string.push_fallback_new_message)
        }
        val userId = root.optLong("user_id", 0L)
            .takeIf { it != 0L }
            ?: custom.optLong("user_id", 0L).takeIf { it != 0L }
        val chatId = when {
            custom.optLong("encryption_id", 0L) > 0L ->
                -2_000_000_000_000L + custom.optLong("encryption_id")
            custom.optLong("channel_id", 0L) > 0L ->
                -1_000_000_000_000L - custom.optLong("channel_id")
            custom.optLong("chat_id", 0L) > 0L -> -custom.optLong("chat_id")
            custom.optLong("from_id", 0L) > 0L -> custom.optLong("from_id")
            else -> null
        }
        val messageId = custom.optLong("msg_id", 0L)
            .takeIf { it > 0L }
            ?.shl(20)
        val tapPayload = if (chatId != null) {
            JSONObject().apply {
                put("chat_id", chatId)
                if (messageId != null) put("message_id", messageId)
                put("title", title)
                if (userId != null) put("account_user_id", userId)
            }.toString()
        } else {
            null
        }
        return Parsed(title, body, chatId, tapPayload)
    }
}
