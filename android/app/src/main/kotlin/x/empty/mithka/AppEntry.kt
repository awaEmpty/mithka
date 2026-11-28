package x.empty.mithka

import android.content.Context
import android.content.Intent

/**
 * The single place that builds an "open the app" intent.
 *
 * Only ONE of the icon aliases is enabled at a time, and the launcher starts
 * that alias. `Intent(context, MainActivity::class.java)` names the activity the
 * alias points AT — a different COMPONENT — so Android cannot reuse the running
 * instance: LAUNCH_SINGLE_TOP matches on the component, and with an empty
 * taskAffinity the launch is placed on top as a new ActivityRecord. That second
 * Activity creates a second FlutterEngine in the same process, and TDLib aborts
 * the process when a second thread enters `td_receive`:
 *
 *   [Client.cpp:285] Receive must not be called simultaneously from two
 *   different threads
 *
 * That is the crash after tapping a message notification (or any internal
 * deep link) while the app is already open. Resolving the launcher intent
 * instead keeps the launch on the component the user is already running, so it
 * arrives as `onNewIntent` on that instance.
 */
object AppEntry {
    fun intent(context: Context): Intent {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        return launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
