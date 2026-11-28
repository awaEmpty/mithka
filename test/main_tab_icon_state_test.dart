//
//  main_tab_icon_state_test.dart
//
//  The bottom bar's icon rule: a tab that is not picked shows its outline
//  glyph and the picked tab fills in with the solid one. The classic bar (the
//  default host) used to read only the outline glyph for every tab, so a
//  selection never changed the silhouette; the glass host swapped, but only
//  behind its own flag.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  /// Outline (quiet) and solid (selected) glyph of every tab, in shell order.
  const tabs = [
    (outline: HeroAppIcons.message, solid: HeroAppIcons.solidMessage),
    (outline: HeroAppIcons.hashtag, solid: HeroAppIcons.solidHashtag),
    (outline: HeroAppIcons.users, solid: HeroAppIcons.solidUsers),
    (outline: HeroAppIcons.star, solid: HeroAppIcons.solidStar),
  ];

  // IconData's equality covers the font family, but its toString prints only
  // the code point — so an outline glyph and its solid twin read as the same
  // value in a failure. Compare an explicit family+code key instead.
  String glyph(IconData data) =>
      '${data.fontFamily ?? 'material'}#${data.codePoint.toRadixString(16)}';

  String iconOf(WidgetTester tester, int index) => glyph(
    tester
        .widget<AppIcon>(
          find.descendant(
            of: find.byKey(ValueKey('bottom-tab-$index')),
            matching: find.byType(AppIcon),
          ),
        )
        .icon
        .data,
  );

  testWidgets('classic bar fills only the picked tab', (tester) async {
    for (var selected = 0; selected < tabs.length; selected++) {
      await _pumpClassicBar(tester, selection: selected);
      for (var i = 0; i < tabs.length; i++) {
        expect(
          iconOf(tester, i),
          glyph(i == selected ? tabs[i].solid.data : tabs[i].outline.data),
          reason: 'tab $i with tab $selected picked',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, variant: android);

  testWidgets('every tab pairs a distinct outline and solid glyph', (
    tester,
  ) async {
    for (final tab in tabs) {
      expect(
        glyph(tab.outline.data),
        isNot(glyph(tab.solid.data)),
        reason: 'a tab whose two glyphs match cannot show its state',
      );
    }
  });
}

Future<void> _pumpClassicBar(
  WidgetTester tester, {
  required int selection,
}) async {
  // The default host: no glass surface, so the bar is the classic container
  // under the labels.
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final accounts = AccountStore(prefs);
  addTearDown(theme.dispose);
  addTearDown(accounts.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
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
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (context) => mainBottomBarForTesting(
                selection: selection,
                onSelect: (_) {},
                onClearUnread: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
