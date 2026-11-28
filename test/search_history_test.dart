//
//  search_history_test.dart
//
//  The search page keeps the chats a search was used to open and lists them
//  above the field, the way exteraless's "Recent" section does: filtered by
//  what is typed, clearable as a whole, removable one row at a time, and
//  owned by the account that searched.
//

import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/chats/search_history_store.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

const _selfUserId = 7;

void main() {
  late StreamController<Map<String, dynamic>> updates;
  setUpAll(() {
    L10nFixtures.load().install();
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          switch (request['@type']) {
            case 'getMe':
              return {'@type': 'user', 'id': _selfUserId, 'first_name': 'Me'};
            case 'getChat':
              final id = request['chat_id'] as int;
              return _chatJson(id, _titles[id] ?? 'Chat $id');
            case 'searchChats':
              return {'@type': 'chats', 'chat_ids': _searchChatIds};
            case 'searchContacts':
              return {'@type': 'users', 'user_ids': <int>[]};
            case 'searchPublicChats':
              return {'@type': 'chats', 'chat_ids': <int>[]};
            case 'getConnectionState':
              return {'@type': 'connectionStateReady'};
            default:
              return {'@type': 'ok'};
          }
        },
        send: (request) async {},
        updates: updates.stream,
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  group('SearchHistoryStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('records newest first, moves repeats to the front and caps', () async {
      final store = SearchHistoryStore();
      addTearDown(store.dispose);
      await store.record(_selfUserId, 11);
      await store.record(_selfUserId, 12);
      expect(await store.load(_selfUserId), [12, 11]);

      await store.record(_selfUserId, 11);
      expect(
        await store.load(_selfUserId),
        [11, 12],
        reason: 'opening a chat already in the list re-stamps its position',
      );

      for (var id = 100; id < 130; id++) {
        await store.record(_selfUserId, id);
      }
      final capped = await store.load(_selfUserId);
      expect(capped.length, SearchHistoryStore.maxEntries);
      expect(capped.first, 129);
    });

    test('keeps every account on its own key', () async {
      final store = SearchHistoryStore();
      addTearDown(store.dispose);
      await store.record(7, 11);
      await store.record(8, 22);
      expect(await store.load(7), [11]);
      expect(await store.load(8), [22]);
      expect(await store.load(null), isEmpty);

      // A second instance reads what the first one wrote.
      final reloaded = SearchHistoryStore();
      addTearDown(reloaded.dispose);
      expect(await reloaded.load(7), [11]);
      expect(await reloaded.load(8), [22]);
    });

    test('removes one chat, a filtered batch, then everything', () async {
      final store = SearchHistoryStore();
      addTearDown(store.dispose);
      await store.record(_selfUserId, 1);
      await store.record(_selfUserId, 2);
      await store.record(_selfUserId, 3);

      await store.remove(_selfUserId, 2);
      expect(await store.load(_selfUserId), [3, 1]);

      await store.removeAll(_selfUserId, [1, 3]);
      expect(await store.load(_selfUserId), isEmpty);

      await store.record(_selfUserId, 4);
      await store.clear(_selfUserId);
      expect(await store.load(_selfUserId), isEmpty);
    });
  });

  group('search page', () {
    setUp(() {
      _searchChatIds = <int>[];
      SharedPreferences.setMockInitialValues({
        'drachma.accountSummaries': jsonEncode([
          {'slot': 0, 'userId': _selfUserId, 'name': 'Me', 'phone': '+100'},
        ]),
      });
    });

    testWidgets('lists the account history above an empty field', (
      tester,
    ) async {
      final history = SearchHistoryStore();
      addTearDown(history.dispose);
      await history.record(_selfUserId, 101);
      await history.record(_selfUserId, 102);
      await _pumpSearch(tester, history);

      expect(
        find.byKey(const ValueKey('search-recent-header')),
        findsOneWidget,
      );
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Beta')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
        reason: 'the most recently searched chat leads the list',
      );
    });

    testWidgets('Clear empties the history after confirmation', (tester) async {
      final history = SearchHistoryStore();
      addTearDown(history.dispose);
      await history.record(_selfUserId, 101);
      await _pumpSearch(tester, history);

      await tester.tap(find.byKey(const ValueKey('search-recent-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-confirm-dialog')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('app-confirm-dialog')),
          matching: find.text(
            AppStrings.t(AppStringKeys.searchHistoryClearAction),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsNothing);
      expect(find.byKey(const ValueKey('search-recent-header')), findsNothing);
      expect(await history.load(_selfUserId), isEmpty);
    });

    testWidgets('a long press removes one entry', (tester) async {
      final history = SearchHistoryStore();
      addTearDown(history.dispose);
      await history.record(_selfUserId, 101);
      await history.record(_selfUserId, 102);
      await _pumpSearch(tester, history);

      await tester.longPress(find.byKey(const ValueKey('search-recent-102')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('app-confirm-dialog')),
          matching: find.text(
            AppStrings.t(AppStringKeys.searchHistoryRemoveAction),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Beta'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(await history.load(_selfUserId), [101]);
    });

    testWidgets('the typed text filters history and de-duplicates results', (
      tester,
    ) async {
      final history = SearchHistoryStore();
      addTearDown(history.dispose);
      await history.record(_selfUserId, 101);
      await history.record(_selfUserId, 102);
      // The live search returns the same chat the history already shows.
      _searchChatIds = <int>[102];
      await _pumpSearch(tester, history);

      await tester.enterText(find.byType(CupertinoTextField), 'Bet');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('a chat recorded while the page is open appears', (
      tester,
    ) async {
      final history = SearchHistoryStore();
      addTearDown(history.dispose);
      await history.record(_selfUserId, 101);
      await _pumpSearch(tester, history);
      expect(find.text('Alpha'), findsOneWidget);

      await history.record(_selfUserId, 103);
      await tester.pumpAndSettle();
      expect(find.text('Gamma'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Gamma')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );
    });
  });
}

final Map<int, String> _titles = {101: 'Alpha', 102: 'Beta', 103: 'Gamma'};

List<int> _searchChatIds = <int>[];

Map<String, dynamic> _chatJson(int id, String title) => {
  '@type': 'chat',
  'id': id,
  'title': title,
  'type': {'@type': 'chatTypePrivate', 'user_id': id},
  'unread_count': 0,
  'positions': <Object?>[],
  'notification_settings': {
    '@type': 'chatNotificationSettings',
    'use_default_mute_for': true,
    'mute_for': 0,
  },
};

Future<void> _pumpSearch(
  WidgetTester tester,
  SearchHistoryStore history,
) async {
  final prefs = await SharedPreferences.getInstance();
  final accounts = AccountStore(prefs);
  addTearDown(accounts.dispose);
  final theme = ThemeController(prefs, initialAccountUserId: _selfUserId);
  addTearDown(theme.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
      ],
      child: MaterialApp(
        home: Scaffold(body: SearchView(historyStore: history)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}
