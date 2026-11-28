package x.empty.mithka

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * Receives UnifiedPush callbacks. Declared in the manifest with the
 * connector's PUSH_EVENT action; the library starts this service even when the
 * app process is cold, which is how push delivery survives process death.
 */
class MithkaUnifiedPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        if (PushServiceStore.mode(this) != PushServiceStore.MODE_UNIFIED) {
            return
        }
        UnifiedPushManager.onNewEndpoint(this, endpoint.url, instance)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        if (PushServiceStore.mode(this) != PushServiceStore.MODE_UNIFIED) {
            return
        }
        UnifiedPushManager.onMessage(this, message.content, instance)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        if (PushServiceStore.mode(this) != PushServiceStore.MODE_UNIFIED) {
            return
        }
        UnifiedPushManager.onRegistrationFailed(this, reason.toString())
    }

    override fun onUnregistered(instance: String) {
        UnifiedPushManager.onUnregistered(this)
    }
}
