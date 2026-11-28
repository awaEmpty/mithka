//
//  The push transport section: the mode picker must change the persisted
//  transport immediately and reveal the UnifiedPush gateway + distributor rows
//  without waiting for a page rebuild from outside.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/notifications/push_service_settings.dart';
import 'package:mithka/settings/push_service_section.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpSection(WidgetTester tester) async {
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(child: PushServiceSection()),
        ),
      ),
    ),
  );
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    PushServiceSettings.shared.initialize(prefs);
  });

  test('fresh installs default to FCM', () async {
    final prefs = await SharedPreferences.getInstance();
    PushServiceSettings.shared.initialize(prefs);
    expect(PushServiceSettings.shared.kind, PushServiceKind.fcm);
    expect(PushServiceSettings.shared.residentNotification, isFalse);
  });

  testWidgets('mode picker persists the transport and reveals its settings', (
    tester,
  ) async {
    await _pumpSection(tester);

    expect(
      find.byKey(const ValueKey('mithkax-push-service-mode')),
      findsOneWidget,
    );
    expect(find.text('Google FCM'), findsOneWidget);
    expect(find.byKey(const ValueKey('mithkax-push-gateway')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mithkax-push-service-mode')));
    await tester.pumpAndSettle();
    expect(find.text('In-app'), findsOneWidget);
    expect(find.text('UnifiedPush'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mithkax-push-kind-unifiedPush')),
    );
    await tester.pumpAndSettle();

    expect(PushServiceSettings.shared.kind, PushServiceKind.unifiedPush);
    expect(find.byKey(const ValueKey('mithkax-push-gateway')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mithkax-push-distributor')),
      findsOneWidget,
    );
  });
}
