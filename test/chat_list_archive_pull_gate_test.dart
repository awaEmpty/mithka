import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/archived_chats_view.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pull-down archive arms on the reference client's two conditions: the
/// row is 85% out (`SNAP_HEIGHT`) AND the pull has lasted the minimum pulling
/// time. Distance alone is not enough — a flick over the top edge must not
/// open the archive, and the spring-back after that flick must not open it
/// either, a third of a second later.

Map<String, dynamic> _chat(
  int id, {
  String list = 'chatListMain',
  int order = 100,
}) => {
  '@type': 'chat',
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

Future<void> _pump(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates,
) async {
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
  for (final chat in [
    _chat(1, order: 300),
    for (var i = 2; i <= 20; i++) _chat(i, order: 300 - i),
    _chat(101, list: 'chatListArchive', order: 50),
  ]) {
    updates.add({'@type': 'updateNewChat', 'chat': chat});
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();

  expect(
    find.byType(ChatListPullDownArchiveSlot),
    findsOneWidget,
    reason: 'fixture must mount the pull-down archive slot',
  );
  expect(
    find.byType(ArchivedChatsRow),
    findsNothing,
    reason: 'the archive row starts hidden — it is only built once revealed',
  );
}

/// Starts a pull on the first chat row (the list rests at the top).
Future<TestGesture> _startPull(WidgetTester tester) async {
  final rowTop = tester.getTopLeft(find.text('Chat 1')).dy;
  final gesture = await tester.startGesture(Offset(200, rowTop + 30));
  await tester.pump(const Duration(milliseconds: 16));
  return gesture;
}

/// 8 x 50 px: far enough to put the archive row fully out on distance alone.
const int _pullSteps = 8;
const double _pullStepPixels = 50;

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
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
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets(
    'a quick flick over the top edge never reveals the archive',
    (tester) async {
      await _pump(tester, updates);

      final gesture = await _startPull(tester);
      for (var i = 0; i < _pullSteps; i++) {
        await gesture.moveBy(const Offset(0, _pullStepPixels));
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason:
            'the pull is deep enough by distance but only lasted ~64ms; the '
            'reference client needs 200ms before it shows the archive',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason:
            'the spring-back after the flick must not arm the reveal once the '
            'frame clock finally passes the minimum pulling time',
      );

      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the same pull reveals the archive once it outlasts the minimum time',
    (tester) async {
      await _pump(tester, updates);

      final gesture = await _startPull(tester);
      for (var i = 0; i < _pullSteps; i++) {
        await gesture.moveBy(const Offset(0, _pullStepPixels));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason: '~128ms of pull is still short of the 200ms budget',
      );

      // Hold the finger down at the top: the reference client measures the
      // pull, not the scroll events, so the next movement after the budget
      // expires arms the archive.
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        find.byType(ArchivedChatsRow),
        findsOneWidget,
        reason: 'past 85% of the row and 200ms the archive row is revealed',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byType(ArchivedChatsRow),
        findsOneWidget,
        reason: 'the reveal survives the release — tapping it opens the chat',
      );

      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a pull held past the budget reveals the archive when the finger lifts',
    (tester) async {
      await _pump(tester, updates);

      // Deep pull, fast: distance is there, the 200ms budget is not.
      final pull = await _startPull(tester);
      for (var i = 0; i < 6; i++) {
        await pull.moveBy(const Offset(0, 60));
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason: '~48ms of pull cannot arm the archive',
      );

      // Hold still — no scroll event will re-check the gate — then let go.
      await tester.pump(const Duration(milliseconds: 300));
      await pull.up();
      await tester.pumpAndSettle();
      expect(
        find.byType(ArchivedChatsRow),
        findsOneWidget,
        reason:
            'the reference client commits the reveal on ACTION_UP once the '
            'pull is past the snap height and the minimum pulling time',
      );

      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the revealed archive row scrolls away like a list row, not a header',
    (tester) async {
      await _pump(tester, updates);

      // Reveal it the deliberate way.
      final pull = await _startPull(tester);
      for (var i = 0; i < _pullSteps; i++) {
        await pull.moveBy(const Offset(0, _pullStepPixels));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await pull.moveBy(const Offset(0, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byType(ArchivedChatsRow), findsOneWidget);
      await pull.up();
      await tester.pumpAndSettle();
      expect(
        find.byType(ArchivedChatsRow),
        findsOneWidget,
        reason: 'the row starts out as part of the list',
      );

      // Scroll forward in small steps. The reference client drops the archive
      // item the moment it leaves the viewport; here that frame is the one
      // where the offset is corrected by the removed row height. A row that
      // stays on screen either way measures how far that frame moved content.
      // A row that stays on screen through the whole scroll, so every frame's
      // movement is measurable.
      final marker = find.text('Chat 10');
      final scroll = await tester.startGesture(
        tester.getCenter(find.text('Chat 1')),
      );
      await tester.pump();
      // Clear the drag's touch slop before measuring frames.
      await scroll.moveBy(const Offset(0, -80));
      await tester.pump();
      final deltas = <double>[];
      double? dropStepDelta;
      for (var i = 0; i < 40; i++) {
        final markerTop = tester.getTopLeft(marker).dy;
        await scroll.moveBy(const Offset(0, -8));
        await tester.pump();
        final stepDelta = tester.getTopLeft(marker).dy - markerTop;
        if (find.byType(ArchivedChatsRow).evaluate().isEmpty) {
          dropStepDelta = stepDelta;
          break;
        }
        deltas.add(stepDelta);
      }
      expect(
        dropStepDelta,
        isNotNull,
        reason:
            'scrolling the archive row out of the list drops it — the '
            'reference client keeps it as an ordinary item, not a header',
      );
      expect(
        dropStepDelta,
        moreOrLessEquals(deltas.last, epsilon: 0.6),
        reason:
            'the drop happens off-screen, so that frame moves the chats '
            'exactly as far as the frames around it — no jump of a row height',
      );
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason: 'the dropped row is no longer part of the list',
      );
      // Come back to the top: the search row is ordinary content and returns,
      // the archive row has to be pulled out again.
      await scroll.moveBy(const Offset(0, -120));
      await tester.pump();
      await scroll.up();
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 300), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chat-list-inline-search')),
        findsOneWidget,
        reason: 'the search row scrolls back in with the top of the list',
      );
      expect(
        find.byType(ArchivedChatsRow),
        findsNothing,
        reason: 'a dropped archive row is only restored by a new pull',
      );

      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
