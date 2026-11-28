package x.empty.mithka

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `mithka/push` bridge: applies the selected transport, starts/stops the
 * in-app keep-alive service, exposes the UnifiedPush registration to Dart, and
 * forwards delivered payloads into the running Flutter engine.
 */
class PushServiceBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
        current = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = activity.applicationContext
        when (call.method) {
            "applyPushService" -> {
                val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                applyPushService(
                    context,
                    (arguments["mode"] as? Number)?.toInt()
                        ?: PushServiceStore.MODE_FCM,
                    arguments["gateway"] as? String
                        ?: PushServiceStore.DEFAULT_GATEWAY,
                    arguments["resident"] as? Boolean ?: false,
                )
                result.success(status(context))
            }

            "getUnifiedPushRegistration" -> {
                result.success(UnifiedPushManager.registration(context))
            }

            "unregisterUnifiedPush" -> {
                UnifiedPushManager.unregister(context)
                result.success(null)
            }

            "setKeepAlive" -> {
                val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                    ?: false
                PushServiceStore.setKeepAliveFallback(context, enabled)
                if (enabled || PushServiceStore.mode(context) == PushServiceStore.MODE_IN_APP) {
                    PushKeepAliveService.start(context)
                } else {
                    PushKeepAliveService.stop(context)
                }
                result.success(status(context))
            }

            "getPushStatus" -> result.success(status(context))

            "consumeNotificationTap" -> {
                result.success(mapOf("payload" to PushServiceStore.takePendingTap(context)))
            }

            "clearFallbackNotifications" -> {
                PushFallbackNotifier.clear(context)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (current === this) current = null
    }

    private fun applyPushService(
        context: Context,
        mode: Int,
        gateway: String,
        resident: Boolean,
    ) {
        PushServiceStore.setMode(context, mode)
        PushServiceStore.setGateway(context, gateway)
        PushServiceStore.setResident(context, resident)
        when (mode) {
            PushServiceStore.MODE_IN_APP -> {
                UnifiedPushManager.unregister(context)
                PushServiceStore.setKeepAliveFallback(context, false)
                PushKeepAliveService.start(context)
            }

            PushServiceStore.MODE_UNIFIED -> {
                PushServiceStore.setKeepAliveFallback(context, false)
                PushKeepAliveService.stop(context)
                UnifiedPushManager.register(context)
            }

            else -> {
                UnifiedPushManager.unregister(context)
                if (PushServiceStore.keepAliveFallback(context)) {
                    PushKeepAliveService.start(context)
                } else {
                    PushKeepAliveService.stop(context)
                }
            }
        }
    }

    private fun status(context: Context): Map<String, Any?> {
        val mode = PushServiceStore.mode(context)
        val registration = UnifiedPushManager.registration(context)
        return mapOf(
            "mode" to mode,
            "resident" to PushServiceStore.resident(context),
            "distributors" to UnifiedPushManager.distributors(context),
            "distributor" to (
                registration?.get("distributor")
                    ?: UnifiedPushManager.currentDistributor(context)?.let {
                        UnifiedPushManager.distributorLabel(context, it)
                    }
                ),
            "endpoint" to registration?.get("endpoint"),
            "registered" to (registration != null && mode == PushServiceStore.MODE_UNIFIED),
            "keepAlive" to PushServiceStore.keepAliveEnabled(context),
            "error" to UnifiedPushManager.error(context),
        )
    }

    companion object {
        const val CHANNEL = "mithka/push"
        private const val TAG = "MithkaPush"

        @Volatile
        private var current: PushServiceBridge? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        fun isEngineAttached(): Boolean = current != null

        private fun onMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                block()
            } else {
                mainHandler.post(block)
            }
        }

        fun deliverRegistration() {
            onMain {
                val bridge = current ?: return@onMain
                val context = bridge.activity.applicationContext
                bridge.channel.invokeMethod(
                    "unifiedPushRegistration",
                    UnifiedPushManager.registration(context),
                )
                bridge.channel.invokeMethod("pushStatus", bridge.status(context))
            }
        }

        fun deliverPayload(payload: String) {
            onMain {
                val bridge = current
                if (bridge == null) {
                    Log.d(TAG, "Dropping push payload: Flutter engine is not attached")
                    return@onMain
                }
                bridge.channel.invokeMethod("pushPayload", payload)
            }
        }

        fun deliverWake() {
            onMain { current?.channel?.invokeMethod("pushWake", null) }
        }

        /** Captures a UnifiedPush fallback notification tap for Dart. */
        fun captureTap(context: Context, intent: Intent?) {
            val target = intent ?: return
            val payload = target.getStringExtra(EXTRA_TAP_PAYLOAD) ?: return
            if (payload.isEmpty()) return
            if (current == null) {
                // The engine is not up yet (cold start): keep the tap for Dart's
                // first registration pass instead of dropping it.
                PushServiceStore.setPendingTap(context.applicationContext, payload)
            } else {
                onMain {
                    current?.channel?.invokeMethod("notificationTap", payload)
                }
            }
            target.removeExtra(EXTRA_TAP_PAYLOAD)
        }

        const val EXTRA_TAP_PAYLOAD = "mithka.push.tap_payload"
    }
}
