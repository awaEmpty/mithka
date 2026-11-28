//
//  app_haptics_test.dart
//
//  The app-wide vibration switch and the Android delivery path: every tick is
//  gated by the switch, Android turns the reference client's three ticks into
//  the native `vibrate` call (which fires `performHapticFeedback` with the
//  "ignore the system setting" flags), and any other platform — or an engine
//  without the native bridge — falls back to Flutter's own haptics channel.
//

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/platform/app_haptics.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final nativeCalls = <MethodCall>[];
  final frameworkCalls = <MethodCall>[];

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    nativeCalls.clear();
    frameworkCalls.clear();
    messenger.setMockMethodCallHandler(AppHaptics.channel, (call) async {
      nativeCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      frameworkCalls.add(call);
      return null;
    });
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(AppHaptics.channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    AppHaptics.shared.setEnabled(true);
  });

  test(
    'ticks by default and routes them to the native bridge on Android',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      AppHaptics.shared.initialize(await SharedPreferences.getInstance());

      expect(AppHaptics.shared.enabled, isTrue);
      await AppHaptics.longPress();

      expect(nativeCalls, hasLength(1));
      expect(nativeCalls.single.method, 'vibrate');
      expect(nativeCalls.single.arguments, 'longPress');
      expect(frameworkCalls, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('the three ticks keep the reference names', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());

    await AppHaptics.tap();
    await AppHaptics.longPress();
    await AppHaptics.error();

    expect(nativeCalls.map((call) => call.arguments).toList(), [
      'tap',
      'longPress',
      'error',
    ]);
    debugDefaultTargetPlatformOverride = null;
  });

  test('the switch stops both delivery paths', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());
    AppHaptics.shared.setEnabled(false);
    await AppHaptics.error();
    expect(nativeCalls, isEmpty);
    expect(frameworkCalls, isEmpty);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await AppHaptics.tap();
    expect(nativeCalls, isEmpty);
    expect(frameworkCalls, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  test('the switch persists', () async {
    SharedPreferences.setMockInitialValues({
      'mithka.haptics.enabled.v1': false,
    });
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());
    expect(AppHaptics.shared.enabled, isFalse);

    var notified = 0;
    void listener() => notified += 1;
    AppHaptics.shared.addListener(listener);
    addTearDown(() => AppHaptics.shared.removeListener(listener));
    AppHaptics.shared.setEnabled(true);
    expect(AppHaptics.shared.enabled, isTrue);
    expect(notified, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('mithka.haptics.enabled.v1'), isTrue);
  });

  test('other platforms keep the framework haptics channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());

    await AppHaptics.tap();
    expect(nativeCalls, isEmpty);
    expect(frameworkCalls, hasLength(1));
    expect(frameworkCalls.single.method, 'HapticFeedback.vibrate');
    expect(frameworkCalls.single.arguments, 'HapticFeedbackType.lightImpact');
    debugDefaultTargetPlatformOverride = null;
  });

  test('a shell without the bridge still ticks', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(AppHaptics.channel, null);
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());

    await AppHaptics.longPress();
    expect(nativeCalls, isEmpty);
    expect(frameworkCalls, hasLength(1));
    expect(frameworkCalls.single.arguments, 'HapticFeedbackType.heavyImpact');
    debugDefaultTargetPlatformOverride = null;
  });

  test('a refused native tick falls back to the framework channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      AppHaptics.channel,
      (call) async => false,
    );
    AppHaptics.shared.initialize(await SharedPreferences.getInstance());

    await AppHaptics.error();
    expect(frameworkCalls, hasLength(1));
    // Flutter's vibrate() sends the method with no argument at all.
    expect(frameworkCalls.single.arguments, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('no surface bypasses the wrapper', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('lib/platform/app_haptics.dart')) continue;
      // Comments may name the framework API; only real calls count.
      final code = entity
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      if (code.contains('HapticFeedback')) offenders.add(entity.path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'every vibration must go through AppHaptics',
    );
  });

  test('the Android shell fires the reference constants, not a waveform', () {
    final source = File(
      'android/app/src/main/kotlin/x/empty/mithka/HapticsPlugin.kt',
    ).readAsStringSync();
    // The reference client fires exactly two constants for its interface, and
    // its intensity is whatever the platform assigns those constants. A raw
    // waveform at DEFAULT_AMPLITUDE is louder than any platform tick, so no
    // path may use one; a refused tick answers false and Dart falls back to
    // Flutter's channel instead.
    expect(source, contains('performHapticFeedback(constant, FLAGS)'));
    expect(
      source,
      contains('HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING'),
    );
    // The system-wide touch-vibration switch stays authoritative, like
    // exteraless's own vibrate helper; ignoring it made the ticks stronger.
    expect(source, isNot(contains('FLAG_IGNORE_GLOBAL_SETTING')));
    expect(
      source,
      contains('"longPress", "error" -> HapticFeedbackConstants.LONG_PRESS'),
    );
    expect(source, contains('else -> HapticFeedbackConstants.KEYBOARD_TAP'));
    expect(source, isNot(contains('HapticFeedbackConstants.CONFIRM')));
    expect(source, isNot(contains('HapticFeedbackConstants.REJECT')));
    expect(source, isNot(contains('VibrationEffect')));
    expect(source, contains('const val CHANNEL = "mithka/haptics"'));
    final activity = File(
      'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('haptics = HapticsPlugin(this'));
  });

  test('the appearance settings row drives the same switch', () {
    final source = File('lib/settings/appearance_view.dart').readAsStringSync();
    expect(source, contains("ValueKey('settings-haptics')"));
    expect(source, contains('AppHaptics.shared.setEnabled'));
    expect(source, contains('AppStringKeys.mithkaxHapticsTitle'));
  });
}
