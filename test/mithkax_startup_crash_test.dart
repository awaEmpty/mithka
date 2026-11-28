//
//  mithkax_startup_crash_test.dart
//
//  Pins the two device crashes that killed the launch on the loading page, so
//  neither can come back silently:
//
//  1. `ForegroundServiceDidNotStartInTimeException` — every
//     startForegroundService() delivery arms its own five-second timer and
//     only a startForeground() from THAT delivery cancels it
//     (ActiveServices.setServiceForegroundInnerLocked). A latch that answers
//     the first delivery and skips the rest leaves the next timer armed, and
//     the system throws on the main thread → process death.
//  2. `LOG(FATAL)` in Client.cpp `TdReceiver::receive` — td_receive is
//     single-threaded per PROCESS. Killing the receive isolate cannot unwind a
//     native frame it is blocked in (up to 1 s inside td_receive), so a
//     replacement spawned straight after starts a second receiver and the
//     process aborts.
//

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/platform/process_engine.dart';

void main() {
  final service = File(
    'android/app/src/main/kotlin/x/empty/mithka/PushKeepAliveService.kt',
  );
  final td = File('lib/tdlib/td_client.dart');

  late final String kt;
  late final String dart;

  setUpAll(() {
    kt = service.readAsStringSync();
    dart = td.readAsStringSync();
  });

  group('keep-alive service', () {
    test('every start answers startForeground', () {
      expect(
        kt.contains('private var foregroundRequirementSatisfied'),
        isFalse,
        reason:
            'a latch that skips startForeground leaves the next '
            'startForegroundService timer armed → '
            'ForegroundServiceDidNotStartInTimeException',
      );
      final command = kt.substring(
        kt.indexOf('override fun onStartCommand'),
        kt.indexOf('override fun onTaskRemoved'),
      );
      expect(command, contains('goForeground('));
      expect(command, contains('startForeground('), reason: 'via goForeground');
      expect(
        command,
        contains('stopSelf(startId)'),
        reason:
            'a refused startForeground() leaves the timer armed; only taking '
            'the service down cancels it',
      );
    });

    test('startForeground is reached from onStartCommand, not onCreate', () {
      final create = kt.substring(
        kt.indexOf('override fun onCreate'),
        kt.indexOf('override fun onStartCommand'),
      );
      expect(
        create.contains('goForeground'),
        isFalse,
        reason:
            'onCreate is not a startForegroundService delivery; answering '
            'there does not cancel the delivery timer',
      );
      expect(
        kt.contains('ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING'),
        isTrue,
      );
    });
  });

  group('one engine per process', () {
    test('a live sibling engine is never treated as a re-entry', () {
      // Backstop for anyone who reverts to a per-Activity engine.
      const sibling = ProcessEngineState(ordinal: 2);
      expect(sibling.hasLiveSiblingEngine, isTrue);
      expect(sibling.mayReclaimPreviousEngine, isFalse);

      const reentry = ProcessEngineState(ordinal: 2, destroyedOrdinal: 1);
      expect(reentry.hasLiveSiblingEngine, isFalse);
      expect(reentry.mayReclaimPreviousEngine, isTrue);
    });

    test('the engine outlives the Activity', () {
      final activity = File(
        'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
      ).readAsStringSync();
      expect(activity, contains('CachedEngine.acquire(this)'));
      expect(
        activity,
        contains('override fun getCachedEngineId(): String = CachedEngine.ID'),
        reason:
            'a cached engine id is what stops FlutterFragment from owning (and '
            'destroying) the engine, and what keeps detachFromFlutterEngine() '
            'from throwing when a second Activity attaches',
      );
      final cached = File(
        'android/app/src/main/kotlin/x/empty/mithka/CachedEngine.kt',
      ).readAsStringSync();
      final acquire = cached.substring(
        cached.indexOf('fun acquire(context: Context)'),
      );
      expect(acquire, contains('FlutterEngineCache.getInstance()'));
      expect(
        acquire,
        contains('cache.put(ID, engine)'),
        reason: 'the fragment resolves the engine by id from the cache',
      );
      expect(
        acquire,
        contains('engine.dartExecutor.executeDartEntrypoint('),
        reason:
            'the host skips doInitialFlutterViewRun for cached engines, so the '
            'entrypoint would never run without this',
      );
      expect(
        activity,
        contains('override fun shouldDestroyEngineWithHost(): Boolean = false'),
        reason:
            'a per-Activity engine cannot survive Back, and a process cannot '
            'host two engines: the second one aborts on td_receive',
      );
      // A finished Activity is not an exit. The only allowed kill is the one
      // the icon switch asks for: a launcher re-reads a changed alias only
      // once the process that changed it is gone, so that path is an exit by
      // design and lives in its own function.
      expect(
        RegExp('killProcess').allMatches(activity).length,
        1,
        reason:
            'killing the process on a plain finish takes the live engine '
            'down and the next tap lands in a dying process with no window '
            'to show',
      );
      final quitStart = activity.indexOf('private fun quitAfterIconChange()');
      expect(quitStart, isNonNegative);
      final quitEnd = activity.indexOf(
        'private fun currentTaskBaseComponent()',
        quitStart,
      );
      expect(quitEnd, greaterThan(quitStart));
      expect(
        activity.substring(quitStart, quitEnd),
        contains('Process.killProcess(Process.myPid())'),
        reason: 'the icon switch exit is the one place a kill belongs',
      );
      final destroyStart = activity.indexOf('override fun onDestroy()');
      expect(
        activity.substring(destroyStart).contains('killProcess'),
        isFalse,
        reason: 'finishing the Activity never ends the process',
      );
    });

    test('a warm attach does not re-initialise the engine', () {
      final activity = File(
        'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
      ).readAsStringSync();
      final configure = activity.substring(
        activity.indexOf('override fun configureFlutterEngine'),
        activity.indexOf('webProxyBridge = WebProxyBridge'),
      );
      expect(
        configure,
        contains('if (configuredEngine !== flutterEngine)'),
        reason: 'plugins and the ordinal are engine-scoped, attach is not',
      );
      expect(
        activity,
        contains('private var configuredEngine: FlutterEngine?'),
      );
      final guard = configure.substring(
        configure.indexOf('if (configuredEngine !== flutterEngine)'),
      );
      expect(guard, contains('registerPlugins(flutterEngine)'));
    });

    test('a warm window still delivers its intent', () {
      final activity = File(
        'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
      ).readAsStringSync();
      expect(activity, contains('val warm = CachedEngine.isWarm'));
      expect(
        activity,
        contains('if (!warm) {\n            incomingSharePayload'),
        reason: 'a warm window must not re-parse what onNewIntent will deliver',
      );
      expect(
        activity,
        contains("incoming.action != Intent.ACTION_MAIN"),
        reason:
            'deep links, shares and notification taps opened a new window while '
            'Dart is already running; only MAIN has nothing to deliver',
      );
    });
  });

  group('receive pump', () {
    test('the previous isolate exits before a replacement spawns', () {
      final spawn = dart.substring(
        dart.indexOf('Future<void> _spawnReceiveIsolate()'),
        dart.indexOf('Future<void> _spawnReceiveIsolateLocked()'),
      );
      expect(
        spawn,
        contains('_receiveSpawnOperation'),
        reason: 'two overlapping calls would each retire and then spawn',
      );

      final locked = dart.substring(
        dart.indexOf('Future<void> _spawnReceiveIsolateLocked()'),
        dart.indexOf('void restartReceiveIsolate'),
      );
      final retireAt = locked.indexOf('_retireReceiveIsolate()');
      final spawnAt = locked.indexOf('Isolate.spawn(');
      expect(retireAt, greaterThan(0));
      expect(spawnAt, greaterThan(retireAt));
      expect(
        locked.contains('_receiveIsolate?.kill('),
        isFalse,
        reason:
            'killing an isolate blocked inside td_receive cannot unwind that '
            'frame, and a second receiver aborts the whole process',
      );
    });

    test('the isolate leaves its loop through a stop request', () {
      final entry = dart.substring(dart.indexOf('void _receiveEntry(SendPort'));
      expect(
        entry.contains('while (true)'),
        isFalse,
        reason: 'the loop must be able to publish a stop request',
      );
      expect(entry, contains('while (!stopRequested)'));
      expect(entry, contains('_tdReceiveReady'));
      expect(entry, contains('_tdReceiveStopCommand'));
      expect(
        dart,
        contains("'@type': _tdReceiveReadyType"),
        reason: 'the owner must learn the port it can stop the isolate with',
      );
    });

    test('setTdlibParameters goes out once per client', () {
      expect(dart, contains('final Set<int> _parametersSent = {};'));
      expect(
        dart,
        contains('if (!_parametersSent.add(clientId)) return;'),
        reason:
            'TDLib answers a repeat with "Unexpected setTdlibParameters" — the '
            'startup path sent it three times',
      );
      expect(
        dart,
        contains('_parametersSent.remove(clientId);'),
        reason: 'a rejected or closed client must be able to try again',
      );
    });
  });
}
