//
//  mithkax_icon_section_test.dart
//
//  Pins MithkaX's own app icons:
//
//  - the fork marks live in their own picker section ("Mithka X icons"),
//    never in the motif grid, and the gradient mark is what a fresh install
//    ships (Dart selection + the manifest-enabled primordial alias);
//  - every artwork the picker and the native bridges reference exists on
//    disk, at the size its consumer expects (1024 plates, per-density Android
//    layers);
//  - re-selecting the shipped default routes through a manifest-disabled
//    clone, so only the first explicit choice ever force-closes the task.
//

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/appearance/app_icon_controller.dart';
import 'package:mithka/settings/appearance_view.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

const _channel = MethodChannel('mithka/app_icon');

void _mockBridge({String current = 'mithkax_default'}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        return switch (call.method) {
          'isSupported' => true,
          'currentIcon' => current,
          'setIcon' => null,
          _ => throw MissingPluginException(),
        };
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

/// IHDR width/height, so a mis-scaled layer fails here instead of on device.
(int, int) _pngSize(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path is missing');
  final bytes = file.readAsBytesSync();
  expect(bytes.sublist(0, 8), [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ], reason: '$path is not a PNG');
  final header = ByteData.sublistView(bytes, 16, 24);
  return (header.getUint32(0), header.getUint32(4));
}

/// PNG colour type (IHDR byte 25): 2 = RGB (opaque), 6 = RGBA (alpha).
int _pngColorType(String path) => File(path).readAsBytesSync()[25];

/// Alpha bounds of a decoded PNG, as [left, top, right, bottom] (right/bottom
/// exclusive). [minAlpha] filters the soft drop shadow out (the day plate's is
/// at most 0.28, the night plate's 0.58, while the mark itself never drops below
/// 0.72), so the default keeps everything and 170 measures the mark's ink.
List<int> _alphaBounds(String path, {int minAlpha = 8}) {
  final decoded = image_lib.decodePng(File(path).readAsBytesSync())!;
  var left = decoded.width, top = decoded.height, right = -1, bottom = -1;
  for (var y = 0; y < decoded.height; y++) {
    for (var x = 0; x < decoded.width; x++) {
      if (decoded.getPixel(x, y).a > minAlpha) {
        if (x < left) left = x;
        if (y < top) top = y;
        if (x > right) right = x;
        if (y > bottom) bottom = y;
      }
    }
  }
  return [left, top, right + 1, bottom + 1];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => L10nFixtures.load().install());

  group('catalogue', () {
    test('the fork marks form their own section, outside the motif grid', () {
      expect(AppIconVariant.mithkaXSection, [
        AppIconVariant.mithkaxDefault,
        AppIconVariant.mithkaxGreen,
        AppIconVariant.mithkaxFlame,
        AppIconVariant.mithkaxDefaultNight,
        AppIconVariant.mithkaxGreenNight,
        AppIconVariant.mithkaxFlameNight,
      ]);
      for (final variant in AppIconVariant.mithkaXSection) {
        expect(
          AppIconVariant.visibleFree.contains(variant),
          isFalse,
          reason:
              '${variant.key} belongs to the Mithka X section, not the nine '
              'motif icons',
        );
        expect(
          variant.requiresSupporter,
          isFalse,
          reason: 'the fork marks are never Supporter icons',
        );
        expect(
          variant.hasPlate,
          isTrue,
          reason: 'the picker must preview their real background',
        );
      }
    });

    test('the fork marks keep one fixed appearance', () {
      // A night plate is its own catalogue entry. A day entry that carried a
      // dark twin, a mipmap-night-* layer or an iOS luminosity rendition would
      // repaint the icon the user pinned as soon as the system flipped theme.
      for (final variant in AppIconVariant.mithkaXSection) {
        expect(
          variant.darkAsset,
          isNull,
          reason: '${variant.key} must keep the plate it was chosen for',
        );
      }
      final res = Directory('android/app/src/main/res');
      for (final directory in res.listSync().whereType<Directory>()) {
        if (!directory.path.split('/').last.startsWith('mipmap-night-')) {
          continue;
        }
        for (final file in directory.listSync().whereType<File>()) {
          expect(
            file.path.contains('/ic_launcher_mithkax_'),
            isFalse,
            reason: '${file.path} would swap a fork icon at night',
          );
        }
      }
      for (final set in const [
        'MithkaDefault',
        'MithkaGreen',
        'MithkaFlame',
        'MithkaDefaultNight',
        'MithkaGreenNight',
        'MithkaFlameNight',
      ]) {
        final contents = File(
          'ios/Runner/Assets.xcassets/$set.appiconset/Contents.json',
        ).readAsStringSync();
        expect(
          contents.contains('luminosity'),
          isFalse,
          reason: '$set must not carry an iOS dark rendition',
        );
      }
    });

    test('the launcher icon is the 1024 art cropped to its window', () {
      // Android scales every 108dp layer to the icon and shows the central
      // 72dp, so the DESIGN SQUARE has to map onto that window: the mark keeps
      // the plate's own 60.9% x 63.4% ink and the artwork's optical centre
      // (2.07% left of the square's centre), and the shadow stays inside the
      // window instead of being clipped by the mask.
      for (final variant in AppIconVariant.mithkaXSection) {
        final path =
            'android/app/src/main/res/mipmap-xxxhdpi/'
            'ic_launcher_${variant.key}_foreground.png';
        final ink = _alphaBounds(path, minAlpha: 170);
        final width = (ink[2] - ink[0]) / 4;
        final height = (ink[3] - ink[1]) / 4;
        expect(
          width / 72,
          closeTo(0.61, 0.02),
          reason: '${variant.key} ink is ${width}dp of the 72dp window',
        );
        expect(
          height / 72,
          closeTo(0.63, 0.02),
          reason: '${variant.key} ink is ${height}dp of the 72dp window',
        );
        // Android's safe zone: the 66dp circle inscribed in the window.
        expect(
          math.sqrt(math.pow(width / 2, 2) + math.pow(height / 2, 2)),
          lessThanOrEqualTo(33),
          reason: '${variant.key} ink escapes the safe circle',
        );
        // The artwork's optical centre, not the mark bbox on the canvas: the
        // mark sits 21.2/1024 of the design (1.5dp of the window) to the left.
        expect((ink[0] + ink[2]) / 8, closeTo(52.5, 0.6));
        expect((ink[1] + ink[3]) / 8, closeTo(54.0, 0.6));
        // The drop shadow (alpha above the mark, below it) must not reach the
        // edge-clamp band: the design square IS the visible window.
        final full = _alphaBounds(path);
        expect(full[0], greaterThanOrEqualTo(72));
        expect(full[1], greaterThanOrEqualTo(72));
        expect(full[2], lessThanOrEqualTo(360));
        expect(full[3], lessThanOrEqualTo(360));
      }
    });

    test('every referenced artwork exists at its expected size', () {
      for (final variant in AppIconVariant.values) {
        final light = variant.asset;
        expect(_pngSize(light), (1024, 1024), reason: '${variant.key} plate');
        final dark = variant.darkAsset;
        if (dark != null) {
          expect(_pngSize(dark), (1024, 1024), reason: '${variant.key} dark');
        }
        for (final brightness in Brightness.values) {
          final picker = variant.hasPlate
              ? variant.platedPickerAsset(brightness)
              : variant.pickerAsset;
          expect(
            File(picker).existsSync(),
            isTrue,
            reason: '${variant.key} ($brightness) has no picker art: $picker',
          );
        }
      }
    });

    test('the Android launcher carries every fork mark at every density', () {
      const densities = {
        'mdpi': 1,
        'hdpi': 1.5,
        'xhdpi': 2,
        'xxhdpi': 3,
        'xxxhdpi': 4,
      };
      // Derived from the catalogue, not a second list: a mark added to the
      // picker without its launcher resources fails right here.
      for (final variant in AppIconVariant.mithkaXSection) {
        final name = variant.key;
        for (final entry in densities.entries) {
          final factor = entry.value;
          expect(
            _pngSize(
              'android/app/src/main/res/mipmap-${entry.key}/'
              'ic_launcher_$name.png',
            ),
            ((48 * factor).round(), (48 * factor).round()),
            reason: 'legacy 48dp layer for $name in ${entry.key}',
          );
          final backgroundPath =
              'android/app/src/main/res/mipmap-${entry.key}/'
              'ic_launcher_${name}_background.png';
          expect(
            _pngSize(backgroundPath),
            ((108 * factor).round(), (108 * factor).round()),
            reason: 'adaptive 108dp plate for $name in ${entry.key}',
          );
          expect(
            _pngColorType(backgroundPath),
            2,
            reason: 'the plate layer must be opaque RGB',
          );
          // The mark lives in its OWN layer: Android scales a background layer
          // to the full 108dp and crops it to the visible 72dp window, which
          // rendered the mark 1.5x larger than the picker preview when the flat
          // design sat in the background layer.
          final foregroundPath =
              'android/app/src/main/res/mipmap-${entry.key}/'
              'ic_launcher_${name}_foreground.png';
          expect(
            _pngSize(foregroundPath),
            ((108 * factor).round(), (108 * factor).round()),
            reason: 'adaptive 108dp foreground for $name in ${entry.key}',
          );
          expect(
            _pngColorType(foregroundPath),
            6,
            reason: 'the mark layer must carry alpha',
          );
        }
        final adaptive = File(
          'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_$name.xml',
        ).readAsStringSync();
        expect(
          adaptive.contains(
            '<background android:drawable="@mipmap/ic_launcher_${name}_background" />',
          ),
          isTrue,
          reason: 'the plate is the background layer',
        );
        expect(
          adaptive.contains(
            '<foreground android:drawable="@mipmap/ic_launcher_${name}_foreground" />',
          ),
          isTrue,
          reason: 'the mark is the foreground layer, inside the 72dp safe zone',
        );
      }
    });
  });

  group('controller default', () {
    test('a fresh install selects the Mithka X gradient mark', () async {
      _mockBridge();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(prefs);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(controller.currentVariant, AppIconVariant.mithkaxDefault);
      expect(
        controller.firstChangePending,
        isTrue,
        reason: 'the shipped default is still live: the one-time note applies',
      );
    });

    test(
      'the native current for the shipped default is mithkax_default',
      () async {
        _mockBridge();
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final controller = AppIconController(prefs);
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(
          controller.firstChangePending,
          isTrue,
          reason:
              'currentIcon equal to the shipped default must not count as '
              'an explicit choice',
        );
        expect(controller.retainedUnknownState, isNull);
      },
    );

    test('every fork mark is a normal, free choice', () async {
      _mockBridge();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppIconController(prefs);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(
        controller.availableVariants,
        containsAll(AppIconVariant.mithkaXSection),
      );
      for (final variant in AppIconVariant.mithkaXSection) {
        expect(controller.isLocked(variant), isFalse);
        // Selecting the mark that is already applied short-circuits without
        // an explicit write (native state is already right); only a real
        // switch persists the choice. Aurora ships as the default, so the
        // first pass over the section hits exactly that path.
        final alreadyCurrent = controller.isCurrent(variant);
        expect(await controller.setVariant(variant), isTrue);
        if (!alreadyCurrent) {
          expect(prefs.getString('selected_app_icon'), variant.key);
        }
      }
    });

    test('retired fork keys resolve to a surviving mark, never an unknown', () {
      const retired = {
        'mithkax_monochrome': AppIconVariant.mithkaxDefault,
        'mithkax_shadow_light': AppIconVariant.mithkaxDefault,
        'mithkax_shadow_dark': AppIconVariant.mithkaxDefault,
        'mithkax_google_light': AppIconVariant.mithkaxDefault,
        'mithkax_google_dark': AppIconVariant.mithkaxDefault,
        'mithkax_glitch': AppIconVariant.mithkaxDefault,
        // The green predecessor keeps its colour: jade hands over to verdant.
        'mithkax_jade': AppIconVariant.mithkaxGreen,
      };
      for (final entry in retired.entries) {
        expect(
          AppIconVariant.recognizedFromKey(entry.key),
          entry.value,
          reason: '${entry.key} must keep resolving to a shipped mark',
        );
        expect(
          AppIconVariant.values.any((variant) => variant.key == entry.key),
          isFalse,
          reason: '${entry.key} is retired, so it cannot stay in the catalogue',
        );
      }
    });

    test(
      'the retired monochrome key resolves to the shipped default',
      () async {
        _mockBridge();
        // An install that picked the retired mark still holds its key.
        SharedPreferences.setMockInitialValues({
          'selected_app_icon': 'mithkax_monochrome',
        });
        final prefs = await SharedPreferences.getInstance();
        final controller = AppIconController(prefs);
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(
          AppIconVariant.recognizedFromKey('mithkax_monochrome'),
          AppIconVariant.mithkaxDefault,
        );
        expect(controller.currentKey, 'mithkax_default');
        expect(
          controller.retainedUnknownState,
          isNull,
          reason: 'a retired key is history, not an unknown identity',
        );
        expect(controller.firstChangePending, isFalse);
      },
    );
  });

  group('native source pins', () {
    final kt = File(
      'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    test('the shipped launcher alias carries the Mithka X default art', () {
      final applicationTag = manifest.substring(
        0,
        manifest.indexOf('>', manifest.indexOf('<application')),
      );
      expect(
        applicationTag.contains(
          'android:icon="@mipmap/ic_launcher_mithkax_default"',
        ),
        isTrue,
        reason: 'the application icon (App info, task records) is the default',
      );
      final primordial = manifest.substring(
        manifest.indexOf('android:name=".MainActivityLetterMNeutral"'),
      );
      expect(
        primordial
            .substring(0, primordial.indexOf('</activity-alias>'))
            .contains('android:icon="@mipmap/ic_launcher_mithkax_default"'),
        isTrue,
        reason: 'the manifest-enabled alias must show the shipped default art',
      );
      expect(
        kt.contains('return "mithkax_default"'),
        isTrue,
        reason: 'a fresh install must report the new default to the picker',
      );
      expect(
        kt.contains('else "mithkax_default"'),
        isTrue,
        reason: 'an unknown setIcon target falls back to the shipped default',
      );
    });

    test('every fork mark is selectable through a disabled alias', () {
      for (final entry in {
        'mithkax_default': 'MainActivityMithkaXDefaultAlt',
        'mithkax_green': 'MainActivityMithkaXGreen',
        'mithkax_flame': 'MainActivityMithkaXFlame',
        'mithkax_default_night': 'MainActivityMithkaXDefaultNight',
        'mithkax_green_night': 'MainActivityMithkaXGreenNight',
        'mithkax_flame_night': 'MainActivityMithkaXFlameNight',
      }.entries) {
        expect(
          kt.contains('"${entry.key}" to "\$packageName.${entry.value}"'),
          isTrue,
          reason: '${entry.key} has no launcher alias',
        );
        final start = manifest.indexOf('android:name=".${entry.value}"');
        expect(
          start,
          isNot(-1),
          reason: '${entry.value} is not in the manifest',
        );
        expect(
          manifest
              .substring(start, start + 240)
              .contains('android:enabled="false"'),
          isTrue,
          reason: '${entry.value} must ship disabled like every alternative',
        );
      }
    });

    test('the native switch accepts every catalogued key', () {
      // The alias table is the single source of truth for "an icon that
      // exists". A second, hand-maintained key list once held the twelve
      // standard marks and the 48 penguins but not the fork's own two marks,
      // so tapping either answered "cannot change the app icon"
      // (invalid_icon) without ever reaching the launcher.
      expect(
        kt.contains('val freeIcons = setOf('),
        isFalse,
        reason: 'the setIcon gate must consult launcherAliases(), not a copy',
      );
      expect(
        kt.contains('if (!launcherAliases().containsKey(name))'),
        isTrue,
        reason: 'an unknown key is the only thing setIcon may reject',
      );
      for (final variant in AppIconVariant.values) {
        expect(
          kt.contains('"${variant.key}" to "\$packageName.'),
          isTrue,
          reason: '${variant.key} has no launcher alias to switch to',
        );
      }
    });

    test('the iOS bridge maps the same keys', () {
      final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      for (final variant in AppIconVariant.values) {
        expect(
          swift.contains('case "${variant.key}": return '),
          isTrue,
          reason: '${variant.key} has no alternate icon on iOS',
        );
      }
    });
  });

  group('picker section', () {
    testWidgets('the fork marks own the first section of the icon page', (
      tester,
    ) async {
      _mockBridge();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final theme = ThemeController(prefs);
      final controller = AppIconController(prefs);
      addTearDown(theme.dispose);
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider.value(value: controller),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(extensions: [AppColors.light]),
            home: const AppIconSettingsView(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final heading = find.byKey(const ValueKey('app-icon-mithkax-heading'));
      final defaultTile = find.byKey(
        const ValueKey('app-icon-mithkax_default'),
      );
      final greenTile = find.byKey(const ValueKey('app-icon-mithkax_green'));
      final standardHeading = find.byKey(
        const ValueKey('app-icon-standard-heading'),
      );
      expect(heading, findsOneWidget);
      // The shipped en-US value, not the key and not the Chinese UI label.
      expect(tester.widget<Text>(heading).data, 'Mithka X icons');
      expect(defaultTile, findsOneWidget);
      expect(greenTile, findsOneWidget);
      expect(standardHeading, findsOneWidget);

      // A separate section ABOVE the motif grid, default first. Order comes
      // from the widget tree, so it holds regardless of viewport scrolling.
      final order = tester.allWidgets
          .map((widget) => widget.key)
          .whereType<ValueKey<String>>()
          .map((key) => key.value)
          .toList();
      expect(
        order.indexOf('app-icon-mithkax-heading'),
        lessThan(order.indexOf('app-icon-mithkax_default')),
      );
      // All six tiles, in catalogue order: the three colourways then their
      // explicit night plates.
      final sectionTiles = [
        for (final variant in AppIconVariant.mithkaXSection)
          'app-icon-${variant.key}',
      ];
      for (var index = 0; index + 1 < sectionTiles.length; index++) {
        expect(
          order.indexOf(sectionTiles[index]),
          lessThan(order.indexOf(sectionTiles[index + 1])),
          reason: '${sectionTiles[index]} must precede its successor',
        );
      }
      expect(
        order.indexOf(sectionTiles.last),
        lessThan(order.indexOf('app-icon-standard-heading')),
        reason: 'the Mithka X section sits above the standard icons',
      );
      expect(
        order.indexOf(sectionTiles.last),
        lessThan(order.indexOf('app-icon-white')),
        reason: 'the fork marks never appear inside the motif grid',
      );

      // The shipped default is the one marked current.
      expect(
        find.byKey(const ValueKey('icon-selected-mithkax_default')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('icon-selected-mithkax_green')),
        findsNothing,
      );

      // The fork marks never leak into the motif grid or the penguin grid.
      expect(
        find.byKey(const ValueKey('icon-label-white')),
        findsOneWidget,
        reason: 'the nine motif icons still render',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
