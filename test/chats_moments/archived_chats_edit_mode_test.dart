import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/archived_chats_view.dart';
import 'package:mithka/chats/chat_list_view_model.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The archived list carries the same long-press edit mode exteraless gives its
// archive folder (a DialogsActivity with folderId=1 runs the identical action
// mode): body long press selects, the header becomes the SAME command bar the
// main list shows — same height, same 24px glyphs — and every command maps
// onto the archive's own actions.

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          sent.add(request);
          return switch (request['@type']) {
            'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
            'getConnectionState' => {'@type': 'connectionStateReady'},
            'getChat' => {
              '@type': 'chat',
              'id': request['chat_id'],
              'title': 'Archived ${request['chat_id']}',
              'type': {'@type': 'chatTypePrivate', 'user_id': 7},
              'can_be_deleted_only_for_self': true,
              'can_be_deleted_for_all_users': false,
            },
            _ => {'@type': 'ok'},
          };
        },
        send: (request) async {
          sent.add(request);
        },
        updates: updates.stream,
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets(
    'the edit bar matches the main list: height and 24px glyphs',
    (tester) async {
      final model = await _pumpArchive(tester, updates);
      // Same slot math as the main list's own header: one chat-header hit
      // target of content between the bar's own vertical insets.
      final headerHeight =
          AppMetric.chatHeaderHitTarget() +
          2 * (AppSpacing.md + AppSpacing.xxs);
      final normal = tester.getSize(
        find.byKey(const ValueKey('archived-chats-header')),
      );
      expect(normal.height, moreOrLessEquals(headerHeight, epsilon: 0.1));
      await _longPressRow(tester, 'Archived 1');
      expect(
        find.byKey(const ValueKey('chat-list-selection-header')),
        findsOneWidget,
      );
      // Entering edit mode must not shift the list: the command bar occupies
      // exactly the header's height.
      final edit = tester.getSize(
        find.byKey(const ValueKey('chat-list-selection-header')),
      );
      expect(edit.height, moreOrLessEquals(normal.height, epsilon: 0.1));
      // The archive used to draw 18px glyphs in its edit bar; the shared bar
      // draws the header's own toolbar size.
      final pinIcon = tester.widget<AppIcon>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-list-selection-pin')),
          matching: find.byType(AppIcon),
        ),
      );
      expect(pinIcon.size, AppIconSize.toolbar);
      await _dispose(tester);
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'unarchive drives the model for every selected chat',
    (tester) async {
      final model = await _pumpArchive(tester, updates);
      await _longPressRow(tester, 'Archived 1');
      sent.clear();
      await tester.tapAt(_rowBody(tester, 'Archived 2'));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('chat-list-selection-unarchive')),
      );
      await tester.pumpAndSettle();
      final moves = sent.where((r) => r['@type'] == 'addChatToList').toList();
      expect(moves, hasLength(2));
      expect(
        moves.every((r) => (r['chat_list'] as Map)['@type'] == 'chatListMain'),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('chat-list-selection-header')),
        findsNothing,
      );
      await _dispose(tester);
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the overflow column carries the rest of the dialog actions',
    (tester) async {
      final model = await _pumpArchive(tester, updates);
      await _longPressRow(tester, 'Archived 1');
      await tester.tap(
        find.byKey(const ValueKey('chat-list-selection-overflow')),
      );
      await tester.pumpAndSettle();
      // Same anchored popup family as the main list.
      final menu = tester.getSize(
        find.byKey(const ValueKey('chat-list-selection-overflow-menu')),
      );
      expect(menu.width, lessThan(280));
      for (final key in const [
        'chat-list-selection-overflow-read',
        'chat-list-selection-overflow-clear-history',
        'chat-list-selection-overflow-block',
        'chat-list-selection-overflow-select-all',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // The fixtures are all read, so the command flips them to unread.
      await tester.tap(
        find.byKey(const ValueKey('chat-list-selection-overflow-read')),
      );
      await tester.pumpAndSettle();
      final marked = sent
          .where((r) => r['@type'] == 'toggleChatIsMarkedAsUnread')
          .toList();
      expect(marked, hasLength(1));
      expect(marked.single['is_marked_as_unread'], isTrue);
      expect(
        find.byKey(const ValueKey('chat-list-selection-header')),
        findsNothing,
      );
      await _dispose(tester);
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'pin acts on the archive list, not the main list',
    (tester) async {
      final model = await _pumpArchive(tester, updates);
      await _longPressRow(tester, 'Archived 1');
      sent.clear();
      await tester.tap(find.byKey(const ValueKey('chat-list-selection-pin')));
      await tester.pumpAndSettle();
      final pins = sent.where((r) => r['@type'] == 'toggleChatIsPinned');
      expect(pins, hasLength(1));
      expect((pins.single['chat_list'] as Map)['@type'], 'chatListArchive');
      expect(pins.single['is_pinned'], isTrue);
      await _dispose(tester);
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'delete is a confirmation and then a real delete',
    (tester) async {
      final model = await _pumpArchive(tester, updates);
      await _longPressRow(tester, 'Archived 1');
      sent.clear();
      await tester.tap(
        find.byKey(const ValueKey('chat-list-selection-delete')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-confirm-dialog')), findsOneWidget);
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      final deletions = sent
          .where((r) => r['@type'] == 'deleteChatHistory')
          .toList();
      expect(deletions, hasLength(1));
      expect(deletions.single['chat_id'], 101);
      expect(deletions.single['remove_from_chat_list'], isTrue);
      await _dispose(tester);
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

Future<ChatListViewModel> _pumpArchive(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  addTearDown(theme.dispose);

  final model = ChatListViewModel()..onAppear();
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: ArchivedChatsView(model: model),
      ),
    ),
  );

  updates.add({
    '@type': 'updateConnectionState',
    'state': {'@type': 'connectionStateReady'},
  });
  for (final chat in [
    _archivedChat(101, 'Archived 1', 300),
    _archivedChat(102, 'Archived 2', 200),
  ]) {
    updates.add(chat);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
  return model;
}

Map<String, dynamic> _archivedChat(int id, String title, int order) => {
  '@type': 'updateNewChat',
  'chat': {
    '@type': 'chat',
    'id': id,
    'title': title,
    'type': {'@type': 'chatTypePrivate', 'user_id': id},
    'last_message': {
      '@type': 'message',
      'id': order,
      'chat_id': id,
      'date': order,
      'is_outgoing': false,
      'content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'm$id', 'entities': []},
      },
    },
    'positions': [
      {
        '@type': 'chatPosition',
        'list': {'@type': 'chatListArchive'},
        'order': order,
        'is_pinned': false,
      },
    ],
  },
};

Offset _rowBody(WidgetTester tester, String title) {
  final topLeft = tester.getTopLeft(find.text(title));
  return Offset(topLeft.dx + 220, topLeft.dy + 6);
}

Future<void> _longPressRow(WidgetTester tester, String title) async {
  await tester.startGesture(_rowBody(tester, title));
  await tester.pump(kLongPressTimeout);
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}
