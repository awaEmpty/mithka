package x.empty.mithka

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app's UI ticks, using the two constants the reference client uses for
 * its interface: `KEYBOARD_TAP` for taps, toggles, sliders and emoji, and
 * `LONG_PRESS` for long presses, drag lifts and destructive actions. Errors
 * get the `APP_ERROR` rhythm — two presses instead of one.
 *
 * `performHapticFeedback` is the platform's own effect, which is the only path
 * that produces a felt tick on every device (a raw `Vibrator` waveform of a
 * few milliseconds is dropped outright by some HALs). The intensity is
 * therefore exactly the reference client's: it also only ever fires these
 * constants. `FLAG_IGNORE_VIEW_SETTING` keeps the tick alive when a view has
 * haptics disabled; the system-wide touch-vibration switch and its intensity
 * are deliberately NOT bypassed, because exteraless honours them
 * (`AndroidUtilities.vibrate`) and ignoring them was what made the fork's
 * ticks feel stronger than the reference.
 *
 * A refused request answers false and Dart falls back to Flutter's own channel
 * (the same constants, no flags) — a tick can never disappear silently, and no
 * path ever fires a raw full-amplitude waveform.
 */
class HapticsPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val handler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "vibrate") {
            result.notImplemented()
            return
        }
        result.success(vibrate(call.arguments as? String))
    }

    private fun vibrate(kind: String?): Boolean {
        val constant = when (kind) {
            "longPress", "error" -> HapticFeedbackConstants.LONG_PRESS
            else -> HapticFeedbackConstants.KEYBOARD_TAP
        }
        if (!tick(constant)) return false
        if (kind == "error") {
            // APP_ERROR is a double buzz: the second pulse lands 150 ms later.
            handler.postDelayed(
                { tick(HapticFeedbackConstants.LONG_PRESS) },
                ERROR_GAP_MS,
            )
        }
        return true
    }

    /** The platform haptic; false only when the window cannot take it. */
    private fun tick(constant: Int): Boolean {
        val view = activity.window?.decorView ?: return false
        return view.performHapticFeedback(constant, FLAGS)
    }

    fun dispose() {
        handler.removeCallbacksAndMessages(null)
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "mithka/haptics"

        /**
         * Ignore only the *view's* own switch. The global touch-vibration
         * setting stays authoritative, so the user's system intensity applies
         * exactly as it does in the reference client.
         */
        private const val FLAGS = HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING

        /** Gap between the two pulses of an error buzz. */
        private const val ERROR_GAP_MS = 150L
    }
}
