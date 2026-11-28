import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _chat(
  int id, {
  String list = 'chatListMain',
  int order = 100,
}) => {
  'id': id,
  'title': 'Chat $id',
  'type': {'@type': 'chatTypePrivate', 'user_id': 1000 + id},
  'last_message': {
    '@type': 'message',
    'id': id * 10,
    'chat_id': id,
    'date': order,
    'is_outgoing': false,
    'content': {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': 'hi', 'entities': <Object>[]},
    },
  },
  'positions': [
    {
      '@type': 'chatPosition',
      'list': {'@type': list},
      'order': order,
      'is_pinned': false,
    },
  ],
};

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  final haptics = <MethodCall>[];
  // The app's own haptics bridge (Android) — when it is present the tick
  // never reaches Flutter's platform channel, so the test has to listen to
  // both delivery paths and count the tick once.
  const appHaptics = MethodChannel('mithka/haptics');
  final appTicks = <MethodCall>[];
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
          'getConnectionState' => {'@type': 'connectionStateReady'},
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          haptics.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appHaptics, (call) async {
          appTicks.add(call);
          // The shell reports whether the tick landed; answering false/null
          // makes AppHaptics fall back to Flutter's channel and one tick
          // counts twice.
          return true;
        });
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appHaptics, null);
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets(
    'revealing the pull-down archive fires a haptic exactly once',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({
        'communitiesEnabled': false,
        'showChatListSearch': true,
        'archivedChatsDisplayMode': 'pullDown',
      });
      final theme = ThemeController(await SharedPreferences.getInstance());
      addTearDown(theme.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeController>.value(
          value: theme,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [AppLocalizations.delegate],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(extensions: [AppColors.light]),
            home: const Scaffold(body: ChatListView()),
          ),
        ),
      );

      updates.add({
        '@type': 'updateConnectionState',
        'state': {'@type': 'connectionStateReady'},
      });
      updates.add({
        '@type': 'updateNewChat',
        'chat': _chat(101, list: 'chatListArchive', order: 50),
      });
      for (var i = 1; i <= 30; i++) {
        updates.add({
          '@type': 'updateNewChat',
          'chat': _chat(1000 - i, order: 1000 - i),
        });
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      haptics.clear();

      final firstRow = tester.getTopLeft(find.text('Chat 991')).dy;
      final gesture = await tester.startGesture(Offset(200, firstRow + 60));
      await tester.pump(const Duration(milliseconds: 40));
      // A deliberate pull, the way the reference client measures one: 600 px
      // of finger travel over 240 ms. Under the archive parallax that is the
      // ~85% row reveal the latch waits for, and the pull outlasts the 200 ms
      // minimum pulling time.
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 50));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        find.byType(ChatListPullDownArchiveSlot),
        findsOneWidget,
        reason: 'fixture must mount the pull-down archive slot',
      );
      final ticks = <Object?>[
        ...appTicks.where((c) => c.method == 'vibrate').map((c) => c.arguments),
        ...haptics
            .where((c) => c.method == 'HapticFeedback.vibrate')
            .map((c) => c.arguments),
      ];
      expect(
        ticks.length,
        1,
        reason:
            'exactly one tick when the archive reveal latches, whichever '
            'haptics path the platform is on',
      );
      expect(
        ticks.single,
        anyOf('tap', 'HapticFeedbackType.lightImpact'),
        reason:
            'the reveal uses the reference client\'s KEYBOARD_TAP — the '
            'CLOCK_TICK selection haptic is too faint to feel mid-gesture',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
