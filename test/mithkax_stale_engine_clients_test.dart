//
//  stale_engine_clients_test.dart
//
//  Pins the Android re-entry repair: a finished activity's process is reused,
//  so the app can get a SECOND FlutterEngine while the first engine's native
//  TDLib clients are still alive and holding every account's binlog lock.
//
//  - the host's engine counter decides whether a reclaim is due, and an
//    unknown host (no method, exception, 0) must read as a cold start;
//  - the reclaim closes the persisted ids and WAITS for authorizationStateClosed
//    before the replacements are created on the same directories;
//  - live ids are persisted in release too (the gate used to be debug-only);
//  - engine teardown closes the native clients while the VM can still send.
//

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/platform/process_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mithka/app_info');

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  group('engine state', () {
    test('a re-entry reports the host counters', () async {
      answer(
        (call) async => call.method == 'engineState'
            ? <String, Object?>{'ordinal': 2, 'destroyedOrdinal': 1}
            : null,
      );

      final state = await readEngineState(channel);
      expect(state.ordinal, 2);
      expect(state.destroyedOrdinal, 1);
      expect(
        state.mayReclaimPreviousEngine,
        isTrue,
        reason: 'the engine that left the clients behind has been destroyed',
      );
    });

    test('a live previous engine is never reclaimed', () async {
      answer(
        (call) async => call.method == 'engineState'
            ? <String, Object?>{'ordinal': 2, 'destroyedOrdinal': 0}
            : null,
      );

      final state = await readEngineState(channel);
      expect(
        state.mayReclaimPreviousEngine,
        isFalse,
        reason:
            'a configuration change attaches this engine before the previous '
            'Activity onDestroy returns; closing a live session would kill it',
      );
    });

    test('a deeper re-entry needs its own predecessor destroyed', () async {
      answer(
        (call) async => call.method == 'engineState'
            ? <String, Object?>{'ordinal': 3, 'destroyedOrdinal': 1}
            : null,
      );
      expect(
        (await readEngineState(channel)).mayReclaimPreviousEngine,
        isFalse,
      );

      answer(
        (call) async => call.method == 'engineState'
            ? <String, Object?>{'ordinal': 3, 'destroyedOrdinal': 2}
            : null,
      );
      expect((await readEngineState(channel)).mayReclaimPreviousEngine, isTrue);
    });

    test('an older host without the method reads as a cold start', () async {
      answer((call) async => throw MissingPluginException());

      final state = await readEngineState(channel);
      expect(state.ordinal, 1);
      expect(state.mayReclaimPreviousEngine, isFalse);
    });

    test('a zero or negative answer reads as a cold start', () async {
      for (final answerValue in <Object?>[
        <String, Object?>{'ordinal': 0, 'destroyedOrdinal': 0},
        <String, Object?>{'ordinal': -1, 'destroyedOrdinal': 5},
        <String, Object?>{'ordinal': null, 'destroyedOrdinal': null},
      ]) {
        answer((call) async => answerValue);

        final state = await readEngineState(channel);
        expect(state.ordinal, 1);
        expect(state.mayReclaimPreviousEngine, isFalse);
      }
    });
  });

  group('startup reclaim (source scan)', () {
    final td = File('lib/tdlib/td_client.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    String between(String start, String end) {
      final from = td.indexOf(start);
      expect(from, isNonNegative, reason: 'missing $start');
      final to = td.indexOf(end, from);
      expect(to, greaterThan(from), reason: 'missing $end after $start');
      return td.substring(from, to);
    }

    test('the reclaim runs before any replacement client is created', () {
      final reclaimCall = td.indexOf('await _reclaimStaleEngineClients();');
      final firstClient = td.indexOf('_bindings.createClientId()');
      expect(reclaimCall, isNonNegative);
      expect(firstClient, isNonNegative);
      expect(
        reclaimCall,
        lessThan(firstClient),
        reason:
            'opening the same database directory before the previous engine '
            'released it is exactly the loading-page failure',
      );
    });

    test('the reclaim waits for the closed acknowledgement, not a timer', () {
      final body = between(
        'Future<void> _reclaimStaleEngineClients()',
        'Future<void> _persistLiveClientIds()',
      );
      expect(
        body,
        contains('_clientClosedWaiters[id] ??='),
        reason: 'authorizationStateClosed is the only release signal',
      );
      expect(body, contains('_tdCloseRequest'));
      expect(body, contains('.timeout('));
      expect(
        body.contains('Future<void>.delayed'),
        isFalse,
        reason: 'a fixed sleep cannot tell whether the lock is gone',
      );
      expect(
        body.contains('Future.any'),
        isFalse,
        reason:
            'a grace period treats a SLOW close as "gone" and lets the '
            'replacement open the binlog mid-close — the 100% crash',
      );
    });

    test('the gate is host-proven, not the build mode', () {
      final gate = between(
        '// Android can attach a SECOND FlutterEngine',
        'final storedBotApiAccounts',
      );
      expect(gate, contains('processEngineState()'));
      expect(gate, contains('engineState.mayReclaimPreviousEngine'));
      expect(gate, contains('kDebugMode ||'));
      expect(gate, contains('await _reclaimStaleEngineClients();'));
    });

    test('live client ids are persisted in release builds too', () {
      expect(
        td.contains('if (kDebugMode) unawaited(_persistLiveClientIds());'),
        isFalse,
        reason: 'a release build must record what a later engine has to close',
      );
      expect(td, contains('unawaited(_persistLiveClientIds());'));
      expect(td.contains('_persistDebugLiveClientIds'), isFalse);
    });

    test('one closer only: teardown must not race the reclaim', () {
      expect(
        main.contains('closeClientsForNativeEngineDetach()'),
        isFalse,
        reason:
            'the engine is destroyed milliseconds after `detached`, so a close '
            'sent there may still be running when the next engine opens the '
            'same binlog',
      );
      expect(
        td,
        contains("(object.str('message') ?? '').startsWith('Request aborted')"),
        reason:
            'a client TDLib no longer has answers "Request aborted"; without '
            'that the reclaim waits out the timeout on every cold start',
      );
      expect(
        td,
        contains('final waiter = _clientClosedWaiters.remove(clientId);'),
      );
    });
  });
}
