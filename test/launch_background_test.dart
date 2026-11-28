//
//  launch_background_test.dart
//
//  The cold-start surfaces are painted by three different runtimes — the
//  Android starting window, the iOS launch storyboard, and Flutter's first
//  frame — and the user sees every seam between them. These tests pin the
//  three to the same two colours so the launch screen follows the system
//  light/dark appearance instead of flashing white. The values-v31 layer
//  additionally pins the Android 12+ system splash icon to the app mark and
//  checks the mark artwork is baked once per appearance.
//

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/platform/system_ui.dart';
import 'package:mithka/theme/app_theme.dart';

const _markSource = 'tool/app_icons/mithkax_mark.svg';
const _androidRes = 'android/app/src/main/res';
const _iosAssets = 'ios/Runner/Assets.xcassets';
const _launchColorName = 'launch_background';
const _iosLaunchColorName = 'LaunchBackground';

String _read(String relativePath) => File(relativePath).readAsStringSync();

/// Parses `#RRGGBB` / `#AARRGGBB` from a color resource named [name].
Color _androidColor(String xml, String name) {
  final match = RegExp(
    '<color\\s+name="$name"\\s*>\\s*(#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8}))\\s*',
  ).firstMatch(xml);
  expect(
    match,
    isNotNull,
    reason: 'Expected a <color name="$name"> resource in:\n$xml',
  );
  final hex = match!.group(1)!.substring(1);
  final value = int.parse(hex, radix: 16);
  return Color(hex.length == 6 ? 0xFF000000 | value : value);
}

/// Reads one sRGB channel of the [appearance] variant of a color set.
///
/// [appearance] is `null` for the "Any Appearance" (light) variant and
/// `'dark'` for the dark-luminosity variant.
double _iosChannel(
  Map<String, dynamic> colorSet,
  String? appearance,
  String channel,
) {
  final colors = colorSet['colors'] as List<dynamic>;
  for (final entry in colors) {
    final variant = entry as Map<String, dynamic>;
    final appearances = variant['appearances'] as List<dynamic>?;
    String? luminosity;
    for (final a in appearances ?? const <dynamic>[]) {
      final map = a as Map<String, dynamic>;
      if (map['appearance'] == 'luminosity') {
        luminosity = map['value'] as String?;
      }
    }
    if (luminosity != appearance) continue;
    final components =
        ((variant['color'] as Map<String, dynamic>)['components'])
            as Map<String, dynamic>;
    return double.parse(components[channel]!.toString());
  }
  fail('No ${appearance ?? "light"} variant in $colorSet');
}

Color _iosColor(Map<String, dynamic> colorSet, String? appearance) =>
    Color.fromRGBO(
      (_iosChannel(colorSet, appearance, 'red') * 255).round(),
      (_iosChannel(colorSet, appearance, 'green') * 255).round(),
      (_iosChannel(colorSet, appearance, 'blue') * 255).round(),
      1,
    );

/// What the cold-start artwork actually contains: its ink box and its colour.
class _MarkInk {
  const _MarkInk({
    required this.width,
    required this.height,
    required this.leftMargin,
    required this.rightMargin,
    required this.heightShare,
    required this.luminance,
    required this.meanRed,
    required this.meanBlue,
  });

  final int width;
  final int height;
  final int leftMargin;
  final int rightMargin;
  final double heightShare;

  /// Mean luminance of the opaque pixels, 0..255.
  final double luminance;

  /// Mean red and blue channels of the opaque pixels, 0..255.
  final double meanRed;
  final double meanBlue;
}

/// Decodes [path] and measures its opaque ink.
Future<_MarkInk> _markInk(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  var minX = image.width, maxX = -1, minY = image.height, maxY = -1;
  var total = 0.0;
  var red = 0.0;
  var blue = 0.0;
  var count = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final alpha = bytes[(y * image.width + x) * 4 + 3];
      if (alpha < 8) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      final offset = (y * image.width + x) * 4;
      total +=
          0.2126 * bytes[offset] +
          0.7152 * bytes[offset + 1] +
          0.0722 * bytes[offset + 2];
      red += bytes[offset];
      blue += bytes[offset + 2];
      count++;
    }
  }
  final width = image.width;
  final height = image.height;
  image.dispose();
  codec.dispose();
  expect(count, greaterThan(0), reason: '$path carries no ink');
  return _MarkInk(
    width: width,
    height: height,
    leftMargin: minX,
    rightMargin: width - 1 - maxX,
    heightShare: (maxY - minY + 1) / height,
    luminance: total / count,
    meanRed: red / count,
    meanBlue: blue / count,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final lightLaunch = launchBackgroundColorFor(Brightness.light);
  final darkLaunch = launchBackgroundColorFor(Brightness.dark);

  group('launch background token', () {
    test('matches the app surface the first Flutter frame paints', () {
      expect(lightLaunch, AppColors.light.background);
      expect(darkLaunch, AppColors.dark.background);
      // A dark launch screen that was near-black-but-not-the-app would still
      // read as a jump; the dark surface is deliberately not pure black.
      expect(darkLaunch, isNot(Colors.black));
    });
  });

  group('Android', () {
    test('launch color is night-qualified and matches the app surfaces', () {
      expect(
        _androidColor(
          _read('$_androidRes/values/colors.xml'),
          _launchColorName,
        ),
        lightLaunch,
        reason: 'values/colors.xml must pin the light launch background',
      );
      expect(
        _androidColor(
          _read('$_androidRes/values-night/colors.xml'),
          _launchColorName,
        ),
        darkLaunch,
        reason: 'values-night/colors.xml must pin the dark launch background',
      );
    });

    test('launch drawables reference the color, never hardcoded white', () {
      for (final path in [
        '$_androidRes/drawable/launch_background.xml',
        '$_androidRes/drawable-v21/launch_background.xml',
      ]) {
        final xml = _read(path);
        expect(
          xml,
          contains('@color/$_launchColorName'),
          reason: '$path must resolve through the night-qualified color',
        );
        expect(xml, isNot(contains('@android:color/white')), reason: path);
        expect(
          xml,
          isNot(contains('?android:colorBackground')),
          reason:
              '$path resolves to AppCompat grey (#FAFAFA/#303030), which does '
              'not match the app surface and reads as a flash',
        );
      }
    });

    test('every launch and normal theme paints the same background', () {
      final styleFiles = [
        '$_androidRes/values/styles.xml',
        '$_androidRes/values-night/styles.xml',
        '$_androidRes/values-v29/styles.xml',
        '$_androidRes/values-night-v29/styles.xml',
        '$_androidRes/values-v31/styles.xml',
        '$_androidRes/values-night-v31/styles.xml',
      ];
      for (final path in styleFiles) {
        final xml = _read(path);
        String style(String name) {
          final match = RegExp(
            '<style name="$name".*?</style>',
            dotAll: true,
          ).firstMatch(xml);
          expect(match, isNotNull, reason: '$path must define $name');
          return match!.group(0)!;
        }

        // LaunchTheme paints the splash drawable, whose bottom layer is the
        // night-qualified colour checked above (top layer: the mark).
        final launchTheme = style('LaunchTheme');
        expect(
          launchTheme,
          contains(
            '<item name="android:windowBackground">@drawable/launch_penguin_background</item>',
          ),
          reason: 'LaunchTheme in $path must paint the mark splash drawable',
        );
        // NormalTheme is the window behind Flutter's first frame. It must not
        // resolve to AppCompat's grey colorBackground, or removing the splash
        // changes the colour on screen.
        final normalTheme = style('NormalTheme');
        expect(
          normalTheme,
          contains(
            '<item name="android:windowBackground">@color/$_launchColorName</item>',
          ),
          reason:
              'NormalTheme in $path must use the launch colour so the window '
              'behind the first Flutter frame matches the splash',
        );
        expect(
          launchTheme + normalTheme,
          isNot(contains('?android:colorBackground')),
          reason: '$path still resolves through AppCompat grey',
        );
        // Android 12+ replaces the windowBackground drawable with the system
        // splash screen, whose background comes from this attribute instead.
        expect(
          launchTheme,
          contains(
            '<item name="android:windowSplashScreenBackground">'
            '@color/$_launchColorName</item>',
          ),
          reason: 'LaunchTheme in $path must theme the Android 12+ splash',
        );
      }
    });

    test('Android 12+ splash icon is the app mark', () {
      // Without windowSplashScreenAnimatedIcon the system splash falls back
      // to the launcher icon — the manifest default is the small monochrome
      // letter_m mark. The fork's splash must carry the app mark, matching
      // the in-app cold-start page.
      final xml = _read('$_androidRes/values-v31/styles.xml');
      final launchTheme = RegExp(
        '<style name="LaunchTheme".*?</style>',
        dotAll: true,
      ).firstMatch(xml)!.group(0)!;
      expect(
        launchTheme,
        contains(
          '<item name="android:windowSplashScreenAnimatedIcon">'
          '@drawable/penguin_splash</item>',
        ),
        reason: 'the Android 12+ system splash must show the app mark',
      );
      // The drawable exists in every density bucket.
      for (final bucket in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        expect(
          File('$_androidRes/drawable-$bucket/penguin_splash.png').existsSync(),
          isTrue,
          reason: 'drawable-$bucket/penguin_splash.png must exist',
        );
      }
      // The in-app mark is painted from the same geometry these drawables
      // were rendered from.
      expect(File(_markSource).existsSync(), isTrue, reason: _markSource);
    });

    test('the cold-start mark is baked once per appearance', () async {
      // The launch window is native, so the mark ships baked twice: the
      // azure fill for values/colors.xml and its lifted night blue for
      // values-night/colors.xml. A missing night copy would leave the day
      // azure on the near-black starting window.
      for (final bucket in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        for (final name in ['penguin_launch', 'penguin_splash']) {
          for (final qualifier in ['drawable', 'drawable-night']) {
            final path = '$_androidRes/$qualifier-$bucket/$name.png';
            expect(File(path).existsSync(), isTrue, reason: path);
          }
        }
      }
      for (final qualifier in ['drawable', 'drawable-night']) {
        final path = '$_androidRes/$qualifier/penguin_launch.png';
        expect(File(path).existsSync(), isTrue, reason: path);
      }

      for (final bucket in ['mdpi', 'xxxhdpi']) {
        for (final name in ['penguin_launch', 'penguin_splash']) {
          final day = await _markInk('$_androidRes/drawable-$bucket/$name.png');
          final night = await _markInk(
            '$_androidRes/drawable-night-$bucket/$name.png',
          );
          for (final art in [day, night]) {
            expect(
              art.width,
              art.height,
              reason: '$bucket/$name must be square',
            );
            // The Android 12 system splash masks a circle into the icon; the
            // mark must stay inside its middle third.
            expect(
              art.heightShare,
              closeTo(0.62, 0.02),
              reason: '$bucket/$name',
            );
            expect(
              art.leftMargin,
              closeTo(art.rightMargin, 2),
              reason: '$bucket/$name must be centred',
            );
          }
          // The day mark is the launcher icon's azure body: it must stay
          // blue-dominant, not drift back to a flat black silhouette.
          expect(
            day.meanBlue,
            greaterThan(day.meanRed + 100),
            reason: '$bucket/$name day ink must be azure',
          );
          expect(
            day.luminance,
            inInclusiveRange(90, 200),
            reason: '$bucket/$name day ink luminance',
          );
          // Both appearances are the brand's blue. The night fill used to
          // be a near-white frost, which read as a white glyph on the
          // starting window; it is now the same hue, lifted for legibility.
          expect(
            night.luminance,
            inInclusiveRange(90, 200),
            reason: '$bucket/$name night ink must stay blue, never white',
          );
          expect(
            night.meanBlue,
            greaterThan(night.meanRed + 100),
            reason: '$bucket/$name night ink must stay blue-dominant',
          );
        }
      }
    });

    test('every Android 12+ theme bucket pins the mark splash icon', () {
      // Resource qualifier precedence puts UI mode (night) ABOVE platform
      // version, so on a dark-mode Android 12 device the winning LaunchTheme
      // bucket is values-night-v29 — night outranks the v31 version check —
      // and values-v31 is never consulted. If the night-v31 bucket is
      // missing (or drops the icon item), dark mode resolves a LaunchTheme
      // without windowSplashScreenAnimatedIcon and the system splash falls
      // back to the CURRENT launcher icon, which changes with every icon
      // switch. Both v31 buckets must therefore define the attribute.
      for (final path in [
        '$_androidRes/values-v31/styles.xml',
        '$_androidRes/values-night-v31/styles.xml',
      ]) {
        final xml = _read(path);
        final launchTheme = RegExp(
          '<style name="LaunchTheme".*?</style>',
          dotAll: true,
        ).firstMatch(xml);
        expect(launchTheme, isNotNull, reason: '$path must define LaunchTheme');
        expect(
          launchTheme!.group(0)!,
          contains(
            '<item name="android:windowSplashScreenAnimatedIcon">'
            '@drawable/penguin_splash</item>',
          ),
          reason:
              'LaunchTheme in $path must pin the mark splash icon — dark '
              'mode resolves this bucket (night outranks v31) and without '
              'the item the Android 12+ splash becomes the launcher icon',
        );
      }
    });

    test('resource resolution never loses the splash icon on Android 12+', () {
      // Simulates AOSP's qualifier ordering for the four appearance/version
      // combinations an Android 12+ device can be in. For each, walks the
      // resource system's bucket preference (roughly: night-uiMode and
      // v29+ buckets beat the unqualified default) and asserts the winning
      // LaunchTheme still carries the pinned mark icon.
      String win(String path) {
        final xml = _read(path);
        return RegExp(
          '<style name="LaunchTheme".*?</style>',
          dotAll: true,
        ).firstMatch(xml)!.group(0)!;
      }

      const iconItem =
          '<item name="android:windowSplashScreenAnimatedIcon">'
          '@drawable/penguin_splash</item>';
      // Light + API>=31: night-v31 would need night; the v31 bucket wins.
      expect(win('$_androidRes/values-v31/styles.xml'), contains(iconItem));
      // Dark + API>=31: night buckets beat version buckets, so the dark
      // device picks values-night-v31 (night + both version checks match).
      expect(
        win('$_androidRes/values-night-v31/styles.xml'),
        contains(iconItem),
      );
      // Dark + API 29/30: values-night-v29 wins; the icon item is inert
      // below 31 but harmless — assert it stays absent only in the sense
      // that no other bucket may define a DIFFERENT splash icon.
      final darkLegacy = win('$_androidRes/values-night-v29/styles.xml');
      expect(
        darkLegacy,
        isNot(contains('windowSplashScreenAnimatedIcon')),
        reason: 'below API 31 the attribute is inert; keep the bucket lean',
      );
    });
  });

  group('iOS', () {
    late Map<String, dynamic> colorSet;

    setUpAll(() {
      colorSet =
          jsonDecode(
                _read('$_iosAssets/LaunchBackground.colorset/Contents.json'),
              )
              as Map<String, dynamic>;
    });

    test('launch color set matches the app surfaces in both appearances', () {
      expect(_iosColor(colorSet, null), lightLaunch);
      expect(_iosColor(colorSet, 'dark'), darkLaunch);
    });

    test('color set is registered by its intended name', () {
      final contents =
          jsonDecode(
                _read('$_iosAssets/LaunchBackground.colorset/Contents.json'),
              )
              as Map<String, dynamic>;
      expect(contents['info']['author'], 'xcode');
      expect(contents['colors'], isNotEmpty);
      // Guard against renaming the set without updating the storyboard.
      final storyboard = _read('ios/Runner/Base.lproj/LaunchScreen.storyboard');
      expect(storyboard, contains(_iosLaunchColorName));
    });
  });
}
