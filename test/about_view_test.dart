import 'dart:io';

//
//  about_view_test.dart
//
//  关于 draws the mark as ink, not as a square canvas: the painter hugs the
//  glyph, so the app name sits one gap token under the logo instead of under a
//  band of empty pixels.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/brand_mark.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/about_view.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:mithka/update/update_checker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

void main() {
  setUpAll(() => L10nFixtures.load().install());

  Future<void> pumpAbout(WidgetTester tester, Brightness brightness) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: brightness,
            extensions: [
              brightness == Brightness.dark ? AppColors.dark : AppColors.light,
            ],
          ),
          home: const AboutView(showBackButton: false),
        ),
      ),
    );
    // A ThemeData change animates through AnimatedTheme; settle so the mark
    // reads the appearance it was pumped with.
    await tester.pumpAndSettle();
  }

  testWidgets('the pre-release opt-in sits above check-for-updates, off', (
    tester,
  ) async {
    await pumpAbout(tester, Brightness.light);
    final row = find.byKey(const ValueKey('about-update-prereleases'));
    if (!UpdateChecker.supportsManualCheck) {
      // A Play build has no manual update rows at all; nothing to pin.
      expect(row, findsNothing);
      return;
    }
    expect(row, findsOneWidget);
    final box = tester.widget<AppCheckbox>(
      find.descendant(of: row, matching: find.byType(AppCheckbox)),
    );
    expect(box.value, isFalse, reason: 'official releases are the default');
    final checkRow = find.text(
      AppStrings.t(AppStringKeys.aboutCheckForUpdates),
    );
    expect(checkRow, findsOneWidget);
    expect(
      tester.getRect(row).bottom,
      lessThanOrEqualTo(tester.getRect(checkRow).top + 1),
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UpdateChecker.includePrereleasesKey), isTrue);
    expect(
      tester
          .widget<AppCheckbox>(
            find.descendant(of: row, matching: find.byType(AppCheckbox)),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('the app name sits one gap under the mark', (tester) async {
    await pumpAbout(tester, Brightness.light);

    final mark = find.byType(BrandMark);
    final name = find.text('Mithka X');
    final gap = tester.getTopLeft(name).dy - tester.getBottomLeft(mark).dy;
    expect(gap, AppSpacing.md);
    expect(tester.getSize(mark).height, 84);
  });

  testWidgets('the mark is painted, not bundled as an asset', (tester) async {
    // The fill comes from the theme brand colour at paint time; a raster would
    // freeze it at whatever colour the asset was baked with.
    await pumpAbout(tester, Brightness.light);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(BrandMark), findsOneWidget);
  });

  testWidgets('rows name their destination without printing the address', (
    tester,
  ) async {
    await pumpAbout(tester, Brightness.light);
    // The trailing value slot used to repeat the raw URL on every row; the
    // row title is the destination, the address belongs in the tap.
    expect(find.textContaining('t.me/'), findsNothing);
    expect(find.textContaining('github.com/'), findsNothing);
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('the community chat row points at the fork group', (
    tester,
  ) async {
    await pumpAbout(tester, Brightness.light);
    final source = File('lib/settings/about_view.dart').readAsStringSync();
    expect(source, contains("'https://t.me/mithka'"));
    expect(
      source,
      contains('AppStringKeys.aboutCommunityChat'),
      reason: 'the row must be localized, not a literal',
    );
  });

  testWidgets('the button card sits one lane gap under the version line', (
    tester,
  ) async {
    await pumpAbout(tester, Brightness.light);
    final version = find.byKey(const ValueKey('about-version'));
    final card = find.byType(SettingsCard).first;
    final gap = tester.getTopLeft(card).dy - tester.getBottomLeft(version).dy;
    // The version text keeps a 4px touch pad, then the card follows at lg.
    expect(gap, AppSpacing.xs + AppSpacing.lg);
  });
}
