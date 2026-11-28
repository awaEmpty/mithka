package x.empty.mithka

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the Flutter/TDLib process alive for the in-app push mode.
 *
 * A foreground service is the Android-sanctioned way to hold a socket while
 * the app is backgrounded; exteraless uses the same mechanism. When the
 * unified-push distributor is missing or FCM is unavailable, this service is
 * also the fallback so a self-hosted setup still receives messages.
 */
class PushKeepAliveService : Service() {
    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // EVERY startForegroundService() delivery arms its own five-second
        // timer, and only a startForeground() reached from THAT delivery
        // cancels it (ActiveServices.setServiceForegroundInnerLocked clears
        // SERVICE_FOREGROUND_TIMEOUT_MSG and r.fgRequired when startForeground
        // runs). The previous `foregroundRequirementSatisfied` latch answered
        // the first delivery and then skipped every later one, so the next
        // timer stayed armed until the system threw
        // ForegroundServiceDidNotStartInTimeException on the main thread and
        // killed the process — the crash on the loading page.
        if (!goForeground("onStartCommand")) {
            // A startForeground() that threw (permission, declared type, or a
            // background start that is not allowed) leaves the timer armed.
            // Only taking the service down cancels it.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        scheduleRestart()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopForegroundCompat()
        isRunning = false
        isForeground = false
        if (PushServiceStore.keepAliveEnabled(this)) {
            scheduleRestart()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /// Enters the foreground for the start currently being handled.
    ///
    /// Returns false only when the platform refused the transition, in which
    /// case the caller must take the service down: staying alive without ever
    /// reaching startForeground() is what the system punishes five seconds
    /// later.
    private fun goForeground(reason: String): Boolean {
        val resident = PushServiceStore.resident(this)
        val channelId = if (resident) CHANNEL_VISIBLE else CHANNEL_QUIET
        val notification = buildNotification(channelId, resident)
        val entered = enterForeground(notification, reason)
        isForeground = entered && resident
        if (!resident) {
            // Leaving the foreground is allowed once startForeground() has
            // satisfied this delivery: the service keeps running (START_STICKY
            // + alarm), the resident entry disappears.
            stopForegroundCompat()
        }
        return entered
    }

    private fun enterForeground(notification: Notification, reason: String): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            return true
        } catch (error: Throwable) {
            android.util.Log.w(TAG, "Failed to enter foreground", error)
            isForeground = false
            return false
        }
    }

    private fun buildNotification(channelId: String, resident: Boolean): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_stat_push)
            .setContentTitle(getString(R.string.push_keepalive_title))
            .setContentText(getString(R.string.push_keepalive_text))
            .setShowWhen(false)
            .setOngoing(true)
            .setSilent(!resident)
            .setContentIntent(pendingIntent)
            .setPriority(
                if (resident) NotificationCompat.PRIORITY_LOW
                else NotificationCompat.PRIORITY_MIN,
            )
            .build()
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val visible = NotificationChannel(
            CHANNEL_VISIBLE,
            getString(R.string.push_keepalive_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            setShowBadge(false)
            setSound(null, null)
        }
        val quiet = NotificationChannel(
            CHANNEL_QUIET,
            getString(R.string.push_keepalive_channel_quiet),
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            setShowBadge(false)
            setSound(null, null)
        }
        manager.createNotificationChannels(listOf(visible, quiet))
    }

    private fun scheduleRestart() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, PushKeepAliveService::class.java)
        val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            PendingIntent.getService(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        try {
            alarmManager.cancel(pendingIntent)
            alarmManager.setInexactRepeating(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + 10 * 60 * 1000L,
                10 * 60 * 1000L,
                pendingIntent,
            )
        } catch (error: Throwable) {
            android.util.Log.w(TAG, "Failed to schedule keep-alive restart", error)
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val TAG = "MithkaPush"
        private const val CHANNEL_VISIBLE = "mithka_push_keepalive"
        private const val CHANNEL_QUIET = "mithka_push_keepalive_quiet"
        private const val NOTIFICATION_ID = 0x4D58

        @Volatile
        var isRunning: Boolean = false

        @Volatile
        var isForeground: Boolean = false

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(
                    context.applicationContext,
                    Intent(context.applicationContext, PushKeepAliveService::class.java),
                )
            } catch (error: Throwable) {
                android.util.Log.w(TAG, "Failed to start keep-alive service", error)
            }
        }

        fun stop(context: Context) {
            try {
                context.applicationContext.stopService(
                    Intent(context.applicationContext, PushKeepAliveService::class.java),
                )
            } catch (_: Throwable) {
            }
        }
    }
}
