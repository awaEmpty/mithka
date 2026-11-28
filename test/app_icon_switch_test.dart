//
//  app_icon_switch_test.dart
//
//  Pins the icon-switch mechanics that keep the post-switch cold start alive
//  and the switch UX honest:
//
//  - the native bridge answers currentIcon/setIcon OFF the platform main
//    thread (the crash-once signature: up to 61 serialized PackageManager
//    binder calls on the loading page's UI thread, right after 60 component
//    writes and their PACKAGE_CHANGED broadcast storm);
//  - re-selecting the shipped default routes through the manifest-disabled
//    clone of the primordial alias (MithkaXDefaultAlt, like LetterMNeutralAlt
//    before it), so only the first explicit choice ever transitions the
//    manifest-enabled alias ENABLED -> DISABLED (the one transition Android
//    answers by closing the task);
//  - non-target aliases return to STATE_DEFAULT, not DISABLED — off the kill
//    path for manifest-disabled aliases;
//  - the controller's firstChangePending follows real choice state, so the
//    one-time "app will close once" note appears exactly before the first
//    switch and never again.
//

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/settings/appearance/app_icon_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('controller firstChangePending', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mithka/app_icon'), (
            call,
          ) async {
            return switch (call.method) {
              'isSupported' => true,
              'currentIcon' => 'mithkax_default',
              'setIcon' => null,
              _ => throw MissingPluginException(),
            };
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('mithka/app_icon'),
            null,
          );
    });

    test('pending on a fresh install, cleared by the first switch', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(prefs);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(
        controller.firstChangePending,
        isTrue,
        reason: 'no explicit choice yet: the note must show',
      );

      expect(await controller.setVariant(AppIconVariant.blue), isTrue);
      expect(
        controller.firstChangePending,
        isFalse,
        reason: 'the one-time close is behind us now',
      );
    });

    test(
      'a saved explicit choice is already behind the one-time close',
      () async {
        SharedPreferences.setMockInitialValues({'selected_app_icon': 'blue'});
        final prefs = await SharedPreferences.getInstance();
        final controller = AppIconController(prefs);
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.firstChangePending, isFalse);
      },
    );

    test('a foreign native current (imported state) also counts', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mithka/app_icon'), (
            call,
          ) async {
            return switch (call.method) {
              'isSupported' => true,
              'currentIcon' => 'blue',
              'setIcon' => null,
              _ => throw MissingPluginException(),
            };
          });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(prefs);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(
        controller.firstChangePending,
        isFalse,
        reason:
            'native current differs from the shipped default, so the '
            'manifest-enabled alias was already disabled once',
      );
    });
  });

  group('post-switch behaviour on Android', () {
    // The app no longer exits after a switch: native defers the alias change
    // while this window's task is based on an alias it would disable, applies
    // it when the user leaves and retires the task then. The old moveToBack
    // "step aside" behaviour is gone too.
    test('a successful Android switch no longer steps aside', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mithka/app_icon'), (
            call,
          ) async {
            calls.add(call.method);
            return switch (call.method) {
              'isSupported' => true,
              'currentIcon' => 'mithkax_default',
              'setIcon' => null,
              _ => throw MissingPluginException(),
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('mithka/app_icon'),
              null,
            );
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(
        prefs,
        platform: TargetPlatform.android,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(await controller.setVariant(AppIconVariant.blue), isTrue);
      expect(calls, contains('setIcon'));
      expect(calls, isNot(contains('moveToBack')));
    });

    test('a failed switch never exits', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mithka/app_icon'), (
            call,
          ) async {
            calls.add(call.method);
            return switch (call.method) {
              'isSupported' => true,
              'currentIcon' => 'mithkax_default',
              'setIcon' => throw PlatformException(code: 'app_icon_failed'),
              _ => throw MissingPluginException(),
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('mithka/app_icon'),
              null,
            );
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(
        prefs,
        platform: TargetPlatform.android,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(await controller.setVariant(AppIconVariant.blue), isFalse);
      expect(calls, contains('setIcon'));
    });

    test('non-Android platforms stay put', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mithka/app_icon'), (
            call,
          ) async {
            calls.add(call.method);
            return switch (call.method) {
              'isSupported' => true,
              'currentIcon' => 'mithkax_default',
              'setIcon' => null,
              _ => throw MissingPluginException(),
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('mithka/app_icon'),
              null,
            );
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(prefs, platform: TargetPlatform.iOS);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(await controller.setVariant(AppIconVariant.blue), isTrue);
      expect(calls, contains('setIcon'));
    });
  });

  group('native icon bridge (source scan)', () {
    final kt = File(
      'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    test('currentIcon and setIcon never run on the platform main thread', () {
      expect(
        kt.contains('"currentIcon" -> Thread {'),
        isTrue,
        reason:
            'the up-to-61 PMS reads must leave the UI thread; a freeze '
            'there is the crash-once signature on the first post-switch cold '
            'start',
      );
      // Shape-independent: what matters is that the 61 component writes run
      // inside the worker thread of the setIcon branch, not that they hang off
      // a particular local helper name (an earlier pin on `fun applyIcon()`
      // broke the moment the branch was restructured).
      final branch = kt.substring(kt.indexOf('"setIcon" -> {'));
      final worker = branch.indexOf('Thread {');
      final write = branch.indexOf('setLauncherIcon(name)');
      expect(worker, isNonNegative);
      expect(
        write,
        greaterThan(worker),
        reason: 'the 61 component writes must run on the worker thread',
      );
    });

    test('an icon switch is deferred while its task uses another alias', () {
      // Android finishes every task based on an alias that gets disabled, so
      // the switch waits until the user leaves the app instead of closing it
      // in their face (upstream a5facdfd8). MithkaX's primordial default alias
      // lives outside launcherAliases() and must count as a base alias too.
      expect(
        kt.contains('private const val PENDING_LAUNCHER_ICON = "pending"'),
        isTrue,
      );
      expect(kt.contains('private fun applyPendingLauncherIcon('), isTrue);
      expect(
        kt.contains(
          'val baseAliases = aliases.values + '
          'primordialDefaultAlias.className',
        ),
        isTrue,
        reason:
            'a task opened from the shipped default alias is just as '
            'closeable as one on any other alias',
      );
      expect(kt.contains('baseAliases.contains(base.className)'), isTrue);
      expect(
        kt.contains(
          'if (leftByUser && !isInPictureInPictureMode && '
          '!isChangingConfigurations)',
        ),
        isTrue,
        reason:
            'the deferred switch lands when the user leaves, but never '
            'during PiP or a configuration change',
      );
      expect(kt.contains('finishAndRemoveTask()'), isTrue);
      expect(
        kt.contains(
          'if (isFinishing) applyPendingLauncherIcon(closeTask = false)',
        ),
        isTrue,
        reason: 'Back must still apply the choice without double-finishing',
      );
      final dart = File(
        'lib/settings/appearance/app_icon_controller.dart',
      ).readAsStringSync();
      expect(
        dart.contains('SystemNavigator.pop'),
        isFalse,
        reason:
            'Dart must not close the app after a switch any more: the '
            'native deferral is what keeps it alive',
      );
    });

    test('a landed switch ends the process so the launcher re-reads it', () {
      // A launcher entry keeps the old alias while the process that changed
      // it is alive; the switch therefore asks native to leave once the alias
      // is written, and native applies a deferred switch before it dies.
      final dart = File(
        'lib/settings/appearance/app_icon_controller.dart',
      ).readAsStringSync();
      expect(kt.contains('"quitApp" -> {'), isTrue);
      final quit = kt.substring(
        kt.indexOf('private fun quitAfterIconChange()'),
      );
      final apply = quit.indexOf('applyLauncherIcon(pending)');
      final kill = quit.indexOf('Process.killProcess(Process.myPid())');
      expect(apply, isNonNegative);
      expect(
        kill,
        greaterThan(apply),
        reason:
            'the pending alias must land before the process dies, or the '
            'next open still starts on the old icon',
      );
      expect(
        dart.contains("invokeMethod<void>('quitApp')"),
        isTrue,
        reason: 'Dart has to ask for the exit once the choice is persisted',
      );
    });

    test('re-selecting the shipped default uses the Alt clone', () {
      expect(
        kt.contains(
          '"mithkax_default" to "\$packageName.MainActivityMithkaXDefaultAlt"',
        ),
        isTrue,
        reason:
            'the Mithka X default must route through its manifest-disabled '
            'clone, never the manifest-enabled primordial alias',
      );
      expect(
        kt.contains(
          '"letter_m_neutral" to "\$packageName.MainActivityLetterMNeutralAlt"',
        ),
        isTrue,
        reason:
            'switching back to the neutral default must go through the '
            'manifest-disabled clone, or leaving it again force-closes the app',
      );
      expect(
        manifest.contains('android:name=".MainActivityLetterMNeutralAlt"'),
        isTrue,
        reason: 'the clone alias must exist in the manifest',
      );
      // The clone must ship disabled like every other alternative.
      final cloneBlock = manifest.substring(
        manifest.indexOf('.MainActivityLetterMNeutralAlt'),
      );
      expect(
        cloneBlock.contains('android:enabled="false"'),
        isTrue,
        reason: 'a manifest-enabled clone would show two launcher icons',
      );
    });

    test('cold start self-heals when every alias is dead', () {
      // An update that removed the chosen alias can disable everything; the
      // app then vanishes from the launcher. exteraless runs the same repair.
      expect(
        kt.contains('private fun ensureLauncherAliasEnabled()'),
        isTrue,
        reason: 'the self-heal must exist',
      );
      expect(
        kt.contains('Thread { ensureLauncherAliasEnabled() }.start()'),
        isTrue,
        reason:
            'the repair makes up to 62 PMS reads; on the main thread that '
            'is the same launch freeze this round removed',
      );
      // The repair must re-root at the shipped default, which resolves live
      // from its manifest state. Shape-independent: what matters is that the
      // enabled-state write inside the repair targets `primordialDefaultAlias`
      // (an earlier pin spelled out the indentation and broke on a wrap).
      final repair = kt.substring(
        kt.indexOf('private fun ensureLauncherAliasEnabled()'),
        kt.indexOf('/// Refreshes the recents/switcher entry'),
      );
      final enableCall = repair.indexOf(
        'packageManager.setComponentEnabledSetting(',
      );
      final target = repair.indexOf('primordialDefaultAlias,', enableCall);
      final nextCall = repair.indexOf(
        'packageManager.setComponentEnabledSetting(',
        enableCall + 1,
      );
      expect(
        enableCall,
        isNonNegative,
        reason: 'the repair must write a state',
      );
      expect(
        target,
        allOf(
          greaterThan(enableCall),
          lessThan(nextCall == -1 ? repair.length : nextCall),
        ),
        reason: 'repair targets the primordial alias',
      );
      expect(
        repair,
        contains('PackageManager.COMPONENT_ENABLED_STATE_ENABLED'),
      );
    });

    test('non-target aliases return to STATE_DEFAULT, not DISABLED', () {
      expect(
        kt.contains(
          'component,\n                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,',
        ),
        isTrue,
        reason:
            'STATE_DEFAULT on a manifest-disabled alias is the same '
            'disabled component without the ENABLED->DISABLED runtime '
            'transition that closes the task',
      );
    });

    test('the native side no longer exposes moveToBack', () {
      expect(
        kt.contains('"moveToBack" -> {'),
        isFalse,
        reason: 'moveToBack was removed from the app_icon channel handler',
      );
      expect(
        kt.contains('runOnUiThread { moveTaskToBack(false) }'),
        isFalse,
        reason: 'the moveTaskToBack call was removed with it',
      );
    });

    test('no launch worker thread can kill the process', () {
      // Android's default uncaught-exception handler kills the app on ANY
      // thread. These two run plain `Thread`s out of onCreate/onResume, on the
      // loading page: one RuntimeException out of PackageManager used to take
      // the whole launch down.
      String body(String signature, String next) {
        final from = kt.indexOf(signature);
        expect(from, isNonNegative, reason: 'missing $signature');
        final to = kt.indexOf(next, from);
        expect(to, greaterThan(from), reason: 'missing $next after $signature');
        return kt.substring(from, to);
      }

      final repair = body(
        'private fun ensureLauncherAliasEnabled()',
        '/// Refreshes the recents/switcher entry',
      );
      expect(repair, contains('try {'));
      expect(repair, contains('} catch (error: Exception) {'));

      final taskDescription = body(
        'private fun updateTaskDescription()',
        'private fun requestHighestRefreshRate()',
      );
      expect(taskDescription, contains('try {'));
      expect(taskDescription, contains('} catch (error: Exception) {'));
    });

    test('the recents icon resolves hyphenated catalogue keys', () {
      // `ice-cream`, `high-five`, ... ship as ic_launcher_ice_cream: resource
      // names cannot carry '-'. A raw interpolation answers 0 and hands
      // TaskDescription an icon resource id of 0.
      final taskDescription = kt.substring(
        kt.indexOf('private fun updateTaskDescription()'),
      );
      expect(taskDescription, contains("current.replace('-', '_')"));
      expect(
        taskDescription.contains('ic_launcher_\$current'),
        isFalse,
        reason: 'the key is not the resource name',
      );
    });

    test('the host reports which engine of this process it is', () {
      // Finishing the last activity leaves the process cached, so a re-entry
      // attaches a SECOND engine while the first engine's native TDLib
      // clients still hold every account's binlog lock.
      expect(kt.contains('flutterEngineOrdinal += 1'), isTrue);
      expect(
        kt.contains('"engineState" -> result.success('),
        isTrue,
        reason: 'Dart needs the ordinal AND the destroyed marker',
      );
      expect(
        kt.contains('flutterEngineDestroyedOrdinal = flutterEngineOrdinal'),
        isFalse,
        reason:
            'the engine belongs to the process now: a finished Activity must '
            'not claim that engine died, or the next attach would treat the '
            'still-live session as reclaimable',
      );
      expect(
        kt.contains(
          'override fun shouldDestroyEngineWithHost(): Boolean = false',
        ),
        isTrue,
      );
      expect(kt.contains('private var flutterEngineOrdinal = 0'), isTrue);
      expect(
        kt.contains('private var flutterEngineDestroyedOrdinal = 0'),
        isTrue,
      );
    });
  });
}
