//
//  process_engine.dart
//
//  How many FlutterEngines the current OS process has hosted, and whether the
//  engine that left native state behind is really gone.
//
//  Android does not give an app one process per launch: finishing the last
//  activity leaves a cached process behind, and the next launch attaches a NEW
//  FlutterEngine (and Dart VM) to it. Everything the previous engine created in
//  NATIVE memory survives that VM — TDLib's clients above all — so the second
//  engine has to know it is a re-entry before it opens the same account
//  databases. Every other platform starts a process per engine.
//

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _appInfoChannel = MethodChannel('mithka/app_info');

/// Host-reported engine bookkeeping for this process.
@immutable
class ProcessEngineState {
  const ProcessEngineState({this.ordinal = 1, this.destroyedOrdinal = 0});

  /// 1 = this process has never hosted a FlutterEngine before.
  final int ordinal;

  /// Highest ordinal whose Activity has already been destroyed.
  final int destroyedOrdinal;

  /// True when this engine is a re-entry AND the engine that created the
  /// persisted TDLib clients has definitely finished: the only case where
  /// closing those clients cannot pull a live session out from under its VM.
  bool get mayReclaimPreviousEngine =>
      ordinal > 1 && destroyedOrdinal >= ordinal - 1;

  /// True when an earlier Activity of this process is still alive, i.e. this is
  /// a SECOND engine beside a running one rather than a re-entry.
  ///
  /// That must never reach TDLib: `td_receive` is guarded by one process-wide
  /// lock, the previous engine already holds it, and the newcomer's first call
  /// aborts the process (Client.cpp:285). A configuration change looks the same
  /// for a few milliseconds because this engine is created before the previous
  /// Activity's onDestroy returns, so callers re-read before acting.
  bool get hasLiveSiblingEngine =>
      ordinal > 1 && destroyedOrdinal < ordinal - 1;
}

/// Reads the host's engine bookkeeping. Answers "cold start, nothing to
/// reclaim" when the platform has no such notion or the host lacks it.
Future<ProcessEngineState> processEngineState() async {
  if (!Platform.isAndroid) return const ProcessEngineState();
  return readEngineState(_appInfoChannel);
}

/// Reads [channel]'s engine bookkeeping.
///
/// Split out so a widget test can drive the decision with a mocked channel
/// instead of a real Android host.
@visibleForTesting
Future<ProcessEngineState> readEngineState(MethodChannel channel) async {
  try {
    final state = await channel.invokeMapMethod<String, Object?>('engineState');
    if (state == null) return const ProcessEngineState();
    final ordinal = state['ordinal'];
    final destroyed = state['destroyedOrdinal'];
    return ProcessEngineState(
      ordinal: ordinal is int && ordinal >= 1 ? ordinal : 1,
      destroyedOrdinal: destroyed is int && destroyed >= 0 ? destroyed : 0,
    );
  } catch (_) {
    // An older host answers notImplemented: treat it as a cold start so the
    // launch never waits on a reclaim that cannot have anything to reclaim.
    return const ProcessEngineState();
  }
}
