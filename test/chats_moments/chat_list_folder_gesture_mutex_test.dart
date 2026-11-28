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

/// Scroll offset of the chat list's vertical scrollable.
double _chatListPixels(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    if (element.widget is! Scrollable) continue;
    final state = (element as StatefulElement).state;
    if (state is ScrollableState && state.position.axis == Axis.vertical) {
      return state.position.pixels;
    }
  }
  return double.nan;
}

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

/// Pumps the chat list with two folders plus one chat inside a folder, so the
/// folder pager has somewhere to swipe to.
Future<ThemeController> _pumpFolderPager(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates, {
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'communitiesEnabled': false,
    'showChatListSearch': true,
    ...prefs,
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
    '@type': 'updateChatFolders',
    'chat_folders': [
      {
        'id': 1,
        'title': 'Work',
        'pinned_chat_ids': [201],
        'included_chat_ids': [201],
      },
    ],
  });
  for (var i = 1; i <= 30; i++) {
    updates.add({
      '@type': 'updateNewChat',
      'chat': _chat(1000 - i, order: 1000 - i),
    });
  }
  updates.add({
    '@type': 'updateNewChat',
    'chat': {..._chat(201), 'title': 'Work chat'},
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
  return theme;
}

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
    'a folder drag cancels the vertical scroll it started as',
    (tester) async {
      await _pumpFolderPager(
        tester,
        updates,
        prefs: {'chatListSwipeMode.v1': 'switchFolders'},
      );
      final firstRow = tester.getTopLeft(find.text('Chat 991')).dy;
      final gesture = await tester.startGesture(Offset(200, firstRow + 60));
      await tester.pump(const Duration(milliseconds: 40));
      // Scroll the list upward first — the drag is owned by the vertical
      // scrollable at this point.
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final scrolled = _chatListPixels(tester);
      expect(scrolled, greaterThan(0), reason: 'the list scrolls first');
      // Now bend the same contact sideways into a folder swipe.
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final duringFolderDrag = _chatListPixels(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));
      final afterUp = _chatListPixels(tester);
      expect(
        duringFolderDrag,
        moreOrLessEquals(scrolled, epsilon: 1),
        reason:
            'once the folder drag owns the contact the list must stop '
            'scrolling instead of stacking both axes',
      );
      expect(
        afterUp,
        moreOrLessEquals(scrolled, epsilon: 1),
        reason: 'the list does not inherit leftover drag travel',
      );
      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'scrolling up carries the revealed archive row and the search row out as '
    'list content',
    (tester) async {
      await _pumpFolderPager(
        tester,
        updates,
        prefs: {'archivedChatsDisplayMode': 'pullDown'},
      );
      updates.add({
        '@type': 'updateNewChat',
        'chat': _chat(101, list: 'chatListArchive', order: 50),
      });
      await tester.pump();
      await tester.pumpAndSettle();

      // Reveal the pull-down archive row the deliberate way: past 85% of a
      // row AND past the reference client's 200ms minimum pulling time.
      final firstRow = tester.getTopLeft(find.text('Chat 999')).dy;
      var gesture = await tester.startGesture(Offset(200, firstRow + 60));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 50));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byType(ChatListPullDownArchiveSlot),
        findsOneWidget,
        reason: 'fixture must mount the pull-down archive slot',
      );
      expect(
        find.byType(ArchivedChatsRow),
        findsOneWidget,
        reason:
            'the pull must reveal the archive row before the departure can '
            'be measured',
      );
      // The pill is a list row; once the archive reveal collapsed the layout
      // the search row may already sit offscreen — jump back to the top where
      // the pin assertions below measure it.
      {
        final scrollables = find.byType(Scrollable).evaluate();
        for (final element in scrollables) {
          final state = (element as StatefulElement).state;
          if (state is ScrollableState &&
              state.position.axis == Axis.vertical &&
              state.position.pixels != 0) {
            state.position.jumpTo(0);
          }
        }
        await tester.pump();
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('chat-list-inline-search')),
        findsOneWidget,
        reason: 'fixture must show the search row at the top',
      );

      final searchFinder = find.byKey(
        const ValueKey('chat-list-inline-search'),
      );
      final searchTop = tester.getTopLeft(searchFinder).dy;

      // Scroll up: both leading rows are ordinary list items now, so the
      // search row moves with the finger instead of being held in place while
      // a collapse animation runs.
      gesture = await tester.startGesture(
        Offset(200, tester.getTopLeft(find.text('Chat 999')).dy + 30),
      );
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        _chatListPixels(tester),
        greaterThan(0),
        reason:
            'forward scrolling moves the list — it does not collapse the '
            'leading rows and hand the offset back to the top',
      );
      final movedSearchTop = searchFinder.evaluate().isEmpty
          ? double.negativeInfinity
          : tester.getTopLeft(searchFinder).dy;
      expect(
        movedSearchTop,
        lessThan(searchTop - 0.5),
        reason:
            'the search row scrolls out with the content; it is not held in '
            'place through the archive departure',
      );

      // Keep scrolling until the archive row leaves the viewport: the item is
      // dropped there, exactly like the reference adapter drops it on
      // `firstVisibleItemPosition != 0`. Dropping removes the row's height
      // from the sliver above the viewport, so that same frame hands it back
      // to the scroll offset — the offset steps BACK instead of continuing
      // forward, and the chats stay put.
      var guard = 0;
      double? dropOffsetDelta;
      while (guard++ < 60) {
        final before = _chatListPixels(tester);
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
        final after = _chatListPixels(tester);
        if (find.byType(ArchivedChatsRow).evaluate().isEmpty) {
          dropOffsetDelta = after - before;
          break;
        }
      }
      expect(
        dropOffsetDelta,
        isNotNull,
        reason:
            'the revealed archive row is an ordinary item: scrolling it out '
            'of the viewport drops it',
      );
      expect(
        dropOffsetDelta!,
        lessThan(-5),
        reason:
            'the drop hands the removed row height back to the offset in the '
            'same frame; a row that is merely scrolled off-screen would leave '
            'the offset moving forward',
      );
      expect(
        _chatListPixels(tester),
        greaterThan(0),
        reason:
            'the list keeps its scroll offset through the drop — nothing '
            'collapses back to the top',
      );
      await gesture.up();
      await tester.pumpAndSettle();

      // Back at the top the search row scrolls in again; the archive row does
      // not — it has to be pulled out afresh.
      await tester.dragFrom(const Offset(200, 300), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chat-list-inline-search')),
        findsOneWidget,
        reason: 'the search row is ordinary content and returns with the top',
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
