package x.empty.mithka

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the in-app keep-alive after a reboot when it is the active mode. */
class PushBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!PushServiceStore.keepAliveEnabled(context)) return
        PushKeepAliveService.start(context)
    }
}
