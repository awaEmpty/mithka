//
//  app_haptics.dart
//
//  Every vibration the interface emits goes through here.
//
//  exteraless fires exactly two platform constants for its interface —
//  KEYBOARD_TAP for taps, toggles, sliders and emoji, LONG_PRESS for long
//  presses, drag lifts and destructive actions — plus the APP_ERROR double
//  buzz for errors. The Android shell of this bridge does the same
//  (`HapticsPlugin.kt`) and answers whether the tick landed; when it did not,
//  the tick falls back to Flutter's channel instead of disappearing.
//
//  Intensity is the platform constant's, never a raw waveform: exteraless only
//  ever calls `performHapticFeedback`, so any extra full-amplitude buzz reads
//  as "stronger than the reference". The system touch-vibration switch stays
//  authoritative (only the view's own flag is ignored), exactly like
//  `AndroidUtilities.vibrate` in the reference client.
//
//  The one preference in [AppHaptics] is the app-wide switch: with it off
//  nothing is sent to either channel, so no surface can buzz on its own.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reference client's three ticks.
///
/// [AppHapticKind.tap] is its `KEYBOARD_TAP` (taps, toggles, sliders, emoji,
/// keypad), [AppHapticKind.longPress] its `LONG_PRESS` (long presses, drags,
/// destructive actions) and [AppHapticKind.error] its `APP_ERROR` double buzz.
enum AppHapticKind { tap, longPress, error }

/// App-wide haptics: the on/off switch plus the delivery path.
class AppHaptics extends ChangeNotifier {
  AppHaptics._();

  static final AppHaptics shared = AppHaptics._();

  static const _enabledKey = 'mithka.haptics.enabled.v1';

  /// Carries the tick to the Android shell, which fires the platform haptic
  /// with the ignore flags and reports whether it landed.
  static const MethodChannel channel = MethodChannel('mithka/haptics');

  SharedPreferences? _prefs;
  bool _enabled = true;

  /// Whether the app may vibrate at all.
  bool get enabled => _enabled;

  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _enabled = prefs.getBool(_enabledKey) ?? true;
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    unawaited(_prefs?.setBool(_enabledKey, value) ?? Future<void>.value());
    notifyListeners();
  }

  /// Fires one tick, if the app is allowed to vibrate.
  ///
  /// Android goes through the native bridge; every other platform (and a test
  /// harness without the plugin) keeps Flutter's own channel.
  Future<void> fire(AppHapticKind kind) async {
    if (!_enabled) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        if (await channel.invokeMethod<bool>('vibrate', kind.name) ?? false) {
          return;
        }
      } on MissingPluginException {
        // No native shell (tests, an engine built before this bridge).
      } on PlatformException {
        // Fall through to the framework channel rather than swallow the tick.
      }
    }
    await _flutterFeedback(kind);
  }

  Future<void> _flutterFeedback(AppHapticKind kind) {
    return switch (kind) {
      AppHapticKind.tap => HapticFeedback.lightImpact(),
      AppHapticKind.longPress => HapticFeedback.heavyImpact(),
      AppHapticKind.error => HapticFeedback.vibrate(),
    };
  }

  /// A keyboard-tap tick: row taps, toggles, sliders, emoji, keypad digits.
  static Future<void> tap() => shared.fire(AppHapticKind.tap);

  /// A long-press tick: long-pressing a row, lifting a drag, destructive work.
  static Future<void> longPress() => shared.fire(AppHapticKind.longPress);

  /// The error buzz, the reference client's `APP_ERROR`.
  static Future<void> error() => shared.fire(AppHapticKind.error);
}
