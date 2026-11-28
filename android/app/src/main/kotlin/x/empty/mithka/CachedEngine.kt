package x.empty.mithka

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The one FlutterEngine of this process, published through FlutterEngineCache.
 *
 * A per-Activity engine cannot survive `Back` while the process does, and a
 * process cannot host two engines: TDLib keeps its `td_receive` lock in a
 * process-wide native static, so the second engine's first receive aborts the
 * whole process
 *
 *   [Client.cpp:285] Receive must not be called simultaneously from two
 *   different threads
 *
 * This uses Flutter's own supported route — a CACHED ENGINE ID — rather than an
 * engine handed to the Activity by `provideFlutterEngine`. With a cached id,
 * `FlutterFragment.shouldDestroyEngineWithHost()` resolves to "destroy only if
 * explicitly requested" (it never is), so detaching an Activity neither destroys
 * the engine nor trips
 *
 *   AssertionError: The internal FlutterEngine created by FlutterFragment …
 *   has been attached to by another activity
 *
 * Because the host owns the Dart entrypoint for cached engines
 * (`doInitialFlutterViewRun` skips it), it is executed here. It is posted to the
 * UI task runner, so `main()` starts after the Activity's onCreate/onStart
 * return — by then `configureFlutterEngine` has registered the plugins and
 * channels the bootstrap needs.
 */
object CachedEngine {
    const val ID = "mithka-main"

    /** How many Activities have attached this engine (0 = first launch). */
    @Volatile
    var attachCount: Int = 0
        private set

    /** True when a previous Activity already attached Dart in this process. */
    val isWarm: Boolean
        get() = attachCount > 0

    @Synchronized
    fun acquire(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ID)?.let { return it }
        // Plugins are registered explicitly by MainActivity (it mirrors the
        // generated registry), so automatic registration stays off.
        val engine = FlutterEngine(context.applicationContext, null, false)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        cache.put(ID, engine)
        return engine
    }

    fun noteAttach() {
        attachCount += 1
    }
}
