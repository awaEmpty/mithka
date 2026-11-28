//
//  double_tap_settings_test.dart
//
//  The chat-view settings carry the exteraless double-tap choices (incoming /
//  outgoing) and the avatar presence switch, which must be off by default.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/chat/messages/message_double_tap_action.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/appearance/app_icon_controller.dart';
import 'package:mithka/settings/appearance_view.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<(ThemeController, SharedPreferences)> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final icons = AppIconController(prefs);
  final accounts = AccountStore(prefs);
  addTearDown(theme.dispose);
  addTearDown(icons.dispose);
  addTearDown(accounts.dispose);
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AppIconController>.value(value: icons),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatViewAppearanceSettingsView(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (theme, prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('double-tap actions default to sending a reaction', (
    tester,
  ) async {
    final (theme, _) = await _pump(tester);
    expect(theme.doubleTapIncoming, MessageDoubleTapAction.sendReaction);
    expect(theme.doubleTapOutgoing, MessageDoubleTapAction.sendReaction);
  });

  testWidgets('the incoming action row picks and persists an action', (
    tester,
  ) async {
    final (theme, prefs) = await _pump(tester);
    final row = find.text('Double-tap incoming messages');
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byType(DoubleTapActionSettingsView), findsOneWidget);
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(theme.doubleTapIncoming, MessageDoubleTapAction.reply);
    expect(prefs.getString('doubleTapAction.incoming.v1'), 'reply');
    expect(
      theme.doubleTapOutgoing,
      MessageDoubleTapAction.sendReaction,
      reason: 'the two directions are independent',
    );
  });

  testWidgets('the avatar presence switch is off by default and persists', (
    tester,
  ) async {
    final (theme, prefs) = await _pump(tester);
    expect(theme.showAvatarOnlineStatus, isFalse);
    final row = find.text('Online status on avatars');
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(theme.showAvatarOnlineStatus, isTrue);
    expect(prefs.getBool('avatarOnlineStatus.v1'), isTrue);
  });
}
