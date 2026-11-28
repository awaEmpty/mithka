package x.empty.mithka

import android.content.Context
import android.util.Base64
import android.util.Log
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import org.json.JSONObject
import org.unifiedpush.android.connector.UnifiedPush

/**
 * UnifiedPush plumbing shared by the connector service and the Flutter
 * bridge. Telegram sends WebPush aesgcm messages to a gateway that forwards
 * them to the selected distributor; this object owns the local key pair, the
 * token Telegram sees, and the decryption of delivered messages.
 */
object UnifiedPushManager {
    private const val TAG = "MithkaPush"
    private const val INSTANCE = "default"
    private const val NTFY_DISTRIBUTOR = "io.heckel.ntfy"

    private const val PREFS = "mithka_push_up"
    private const val KEY_PRIVATE = "private_key"
    private const val KEY_PUBLIC = "public_key"
    private const val KEY_AUTH = "auth_secret"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_GATEWAY_ENDPOINT = "gateway_endpoint"
    private const val KEY_SIMPLE_ENDPOINT = "simple_endpoint"
    private const val KEY_DISTRIBUTOR = "distributor"
    private const val KEY_ERROR = "error"

    fun distributors(context: Context): List<String> = try {
        UnifiedPush.getDistributors(context.applicationContext)
    } catch (error: Throwable) {
        Log.w(TAG, "Failed to list UnifiedPush distributors", error)
        emptyList()
    }

    fun currentDistributor(context: Context): String? = try {
        UnifiedPush.getSavedDistributor(context.applicationContext)
    } catch (_: Throwable) {
        null
    }

    fun distributorLabel(context: Context, packageName: String): String = try {
        val info = context.packageManager.getApplicationInfo(packageName, 0)
        context.packageManager.getApplicationLabel(info).toString()
    } catch (_: Throwable) {
        packageName
    }

    /** Registers with the first available distributor when none is saved. */
    fun register(context: Context) {
        val app = context.applicationContext
        val available = distributors(app)
        if (available.isEmpty()) {
            setError(app, "no_distributor")
            PushServiceBridge.deliverRegistration()
            startFallback(app)
            return
        }
        val saved = currentDistributor(app)
        val distributor = saved?.takeIf { available.contains(it) } ?: available.first()
        try {
            UnifiedPush.saveDistributor(app, distributor)
            UnifiedPush.register(app, INSTANCE, "Mithka X", null)
            setDistributor(app, distributor)
            setError(app, null)
        } catch (error: Throwable) {
            Log.w(TAG, "UnifiedPush registration failed", error)
            setError(app, "unified_unavailable")
            startFallback(app)
        }
        PushServiceBridge.deliverRegistration()
    }

    fun unregister(context: Context) {
        val app = context.applicationContext
        try {
            UnifiedPush.unregister(app, INSTANCE)
        } catch (error: Throwable) {
            Log.d(TAG, "UnifiedPush unregister: ${error.message}")
        }
        clearRegistration(app)
    }

    fun onNewEndpoint(context: Context, endpoint: String, instance: String) {
        val app = context.applicationContext
        if (PushServiceStore.mode(app) != PushServiceStore.MODE_UNIFIED) {
            try {
                UnifiedPush.unregister(app, instance)
            } catch (_: Throwable) {
            }
            clearRegistration(app)
            return
        }
        try {
            val keys = ensureKeys(app)
            val gateway = normalizeGateway(PushServiceStore.gateway(app))
            val encodedEndpoint = URLEncoder.encode(endpoint, "UTF-8")
            val webPushEndpoint = "${gateway}aesgcm?e=$encodedEndpoint"
            val distributor = currentDistributor(app)
            val simplePushEndpoint = if (distributor == NTFY_DISTRIBUTOR) {
                endpoint
            } else {
                "$gateway$encodedEndpoint"
            }
            val preferences = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            preferences.edit()
                .putString(KEY_ENDPOINT, endpoint)
                .putString(KEY_GATEWAY_ENDPOINT, webPushEndpoint)
                .putString(KEY_SIMPLE_ENDPOINT, simplePushEndpoint)
                .putString(KEY_DISTRIBUTOR, distributor)
                .remove(KEY_ERROR)
                .apply()
            // Persisting the endpoint is not enough: the token only reaches
            // Telegram when Dart registers it with TDLib.
            PushServiceBridge.deliverRegistration()
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to prepare UnifiedPush endpoint", error)
            setError(app, "unified_unavailable")
            startFallback(app)
            PushServiceBridge.deliverRegistration()
        }
    }

    fun onMessage(context: Context, content: ByteArray, instance: String) {
        val app = context.applicationContext
        if (PushServiceStore.mode(app) != PushServiceStore.MODE_UNIFIED) return
        val keys = loadKeys(app)
        if (keys != null) {
            try {
                val plaintext = WebPushDecryptor.decrypt(
                    content,
                    keys.privateKey,
                    keys.publicKey,
                    keys.authSecret,
                )
                val decoded = String(plaintext, StandardCharsets.UTF_8)
                val payload = try {
                    JSONObject(decoded).optString("p").takeIf { it.isNotEmpty() }
                } catch (_: Throwable) {
                    null
                } ?: decoded
                deliver(app, payload)
                return
            } catch (error: Throwable) {
                Log.d(TAG, "WebPush decrypt failed, trying plaintext: ${error.message}")
            }
        }
        val text = try {
            String(content, StandardCharsets.UTF_8)
        } catch (_: Throwable) {
            ""
        }
        val payload = text.takeIf { it.trim().startsWith("{") && looksLikeTelegramPush(it) }
        if (payload != null) {
            deliver(app, payload)
        } else {
            wake(app)
        }
    }

    fun onRegistrationFailed(context: Context, reason: String) {
        val app = context.applicationContext
        Log.w(TAG, "UnifiedPush registration failed: $reason")
        setError(app, "unified_unavailable")
        startFallback(app)
        PushServiceBridge.deliverRegistration()
    }

    fun onUnregistered(context: Context) {
        val app = context.applicationContext
        clearRegistration(app)
        PushServiceBridge.deliverRegistration()
    }

    /** The registration Telegram should receive, or null before the first endpoint. */
    fun registration(context: Context): Map<String, Any?>? {
        val app = context.applicationContext
        val preferences = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val endpoint = preferences.getString(KEY_GATEWAY_ENDPOINT, null) ?: return null
        val keys = loadKeys(app) ?: return null
        val simpleEndpoint = preferences.getString(KEY_SIMPLE_ENDPOINT, null) ?: endpoint
        val distributor = preferences.getString(KEY_DISTRIBUTOR, null)
        return mapOf(
            "endpoint" to endpoint,
            "p256dh" to base64Url(keys.publicKey),
            "auth" to base64Url(keys.authSecret),
            "simpleEndpoint" to simpleEndpoint,
            "distributor" to distributor?.let { distributorLabel(app, it) },
        )
    }

    fun rawEndpoint(context: Context): String? = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY_ENDPOINT, null)

    fun error(context: Context): String? = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY_ERROR, null)

    private fun setError(context: Context, error: String?) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (error == null) {
            preferences.edit().remove(KEY_ERROR).apply()
        } else {
            preferences.edit().putString(KEY_ERROR, error).apply()
        }
    }

    private fun setDistributor(context: Context, distributor: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DISTRIBUTOR, distributor)
            .apply()
    }

    private fun clearRegistration(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_ENDPOINT)
            .remove(KEY_GATEWAY_ENDPOINT)
            .remove(KEY_SIMPLE_ENDPOINT)
            .remove(KEY_DISTRIBUTOR)
            .remove(KEY_ERROR)
            .apply()
    }

    private fun deliver(context: Context, payload: String) {
        if (PushServiceBridge.isEngineAttached()) {
            PushServiceBridge.deliverPayload(payload)
        } else {
            PushFallbackNotifier.post(context, payload)
        }
    }

    private fun wake(context: Context) {
        if (PushServiceBridge.isEngineAttached()) {
            PushServiceBridge.deliverWake()
        } else {
            PushFallbackNotifier.post(context, null)
        }
    }

    private fun startFallback(context: Context) {
        PushServiceStore.setKeepAliveFallback(context, true)
        PushKeepAliveService.start(context)
    }

    private fun looksLikeTelegramPush(text: String): Boolean =
        text.contains("\"loc_key\"") || text.contains("\"custom\"") ||
            text.contains("\"p\"")

    private fun normalizeGateway(value: String): String {
        val trimmed = value.trim().ifEmpty { PushServiceStore.DEFAULT_GATEWAY }
        return if (trimmed.endsWith("/")) trimmed else "$trimmed/"
    }

    private fun base64Url(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private class Keys(
        val privateKey: ByteArray,
        val publicKey: ByteArray,
        val authSecret: ByteArray,
    )

    private fun loadKeys(context: Context): Keys? {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val privateKey = preferences.getString(KEY_PRIVATE, null) ?: return null
        val publicKey = preferences.getString(KEY_PUBLIC, null) ?: return null
        val authSecret = preferences.getString(KEY_AUTH, null) ?: return null
        return try {
            val privateBytes = Base64.decode(privateKey, Base64.DEFAULT)
            val publicBytes = Base64.decode(publicKey, Base64.DEFAULT)
            val authBytes = Base64.decode(authSecret, Base64.DEFAULT)
            KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(privateBytes))
            if (publicBytes.size != 65 || publicBytes[0] != 0x04.toByte() ||
                authBytes.size != 16
            ) {
                null
            } else {
                Keys(privateBytes, publicBytes, authBytes)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun ensureKeys(context: Context): Keys {
        loadKeys(context)?.let { return it }
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val publicKey = WebPushDecryptor.extractRawPublicKey(
            pair.public as java.security.interfaces.ECPublicKey,
        )
        val privateKey = pair.private.encoded
        val authSecret = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PRIVATE, Base64.encodeToString(privateKey, Base64.DEFAULT))
            .putString(KEY_PUBLIC, Base64.encodeToString(publicKey, Base64.DEFAULT))
            .putString(KEY_AUTH, Base64.encodeToString(authSecret, Base64.DEFAULT))
            .apply()
        return Keys(privateKey, publicKey, authSecret)
    }
}
