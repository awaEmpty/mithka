//
//  topic_tab_menu_test.dart
//
//  A long press on a topic tab opens the same narrow anchored menu as a folder
//  tab — pin / edit / delete, gated by the same rights the topic row menu
//  uses — instead of the wide bottom sheet. The General topic keeps its
//  permanently named identity: pin only, never edit or delete.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/channels/topic_navigation.dart';
import 'package:mithka/channels/topic_tabs_placement.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _forumChatId = -1009012;
const _botChatId = 770001;
const _botUserId = 77;

Map<String, dynamic> _topic(
  int id,
  String name, {
  int lastMessageId = 0,
  bool isPinned = false,
  bool isGeneral = false,
  int chatId = _forumChatId,
  int creatorId = 0,
}) => {
  '@type': 'forumTopic',
  'info': {
    '@type': 'forumTopicInfo',
    'forum_topic_id': id,
    'name': name,
    if (isGeneral) 'is_general': true,
    if (creatorId != 0)
      'creator_id': {'@type': 'messageSenderUser', 'user_id': creatorId},
    'icon': {'@type': 'forumTopicIcon', 'color': 0x6FB9F0},
  },
  'unread_count': 0,
  'is_pinned': isPinned,
  'last_message': {
    '@type': 'message',
    'id': lastMessageId,
    'chat_id': chatId,
    'date': 1700000000 + lastMessageId,
    'is_outgoing': false,
    'sender_id': {'@type': 'messageSenderUser', 'user_id': 5},
    'content': {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': 'last in $name'},
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final updates = StreamController<Map<String, dynamic>>.broadcast();
  final queries = <Map<String, dynamic>>[];

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          queries.add(request);
          switch (request['@type']) {
            case 'getChat':
              if (request['chat_id'] == _botChatId) {
                return {
                  '@type': 'chat',
                  'id': _botChatId,
                  'type': {'@type': 'chatTypePrivate', 'user_id': _botUserId},
                  'title': 'Topics Bot',
                  'unread_count': 0,
                  'permissions': {'can_send_basic_messages': true},
                };
              }
              return {
                '@type': 'chat',
                'id': _forumChatId,
                'type': {'@type': 'chatTypeSupergroup', 'supergroup_id': 9012},
                'title': 'Forum Group',
                'unread_count': 0,
                'permissions': {'can_send_basic_messages': true},
              };
            case 'getUser':
              if (request['user_id'] == _botUserId) {
                return {
                  '@type': 'user',
                  'id': _botUserId,
                  'first_name': 'Topics Bot',
                  'type': {
                    '@type': 'userTypeBot',
                    'has_topics': true,
                    // Lets users pin/edit/delete the bot's topics.
                    'allows_users_to_create_topics': true,
                  },
                };
              }
              return {'@type': 'user', 'id': 5, 'first_name': 'Alice'};
            case 'getSupergroup':
              // Creator: pin and edit ride can_manage_topics, delete rides
              // can_delete_messages — the row menu's own gates.
              return {
                '@type': 'supergroup',
                'id': 9012,
                'is_forum': true,
                'status': {'@type': 'chatMemberStatusCreator'},
              };
            case 'getSupergroupFullInfo':
              return {'@type': 'supergroupFullInfo', 'member_count': 8};
            case 'getForumTopics':
              if (request['chat_id'] == _botChatId) {
                return {
                  '@type': 'forumTopics',
                  'topics': [
                    // Started by the bot account on purpose: Telegram still
                    // offers Delete on every topic of a bot topic chat.
                    _topic(
                      900,
                      'Releases',
                      chatId: _botChatId,
                      lastMessageId: 9000,
                      creatorId: 9,
                    ),
                  ],
                  'total_count': 1,
                };
              }
              return {
                '@type': 'forumTopics',
                'topics': [
                  _topic(
                    1,
                    'General',
                    lastMessageId: 10,
                    isPinned: true,
                    isGeneral: true,
                  ),
                  _topic(50, 'Announcements', lastMessageId: 500),
                ],
                'total_count': 2,
              };
            case 'getMe':
              return {'@type': 'user', 'id': 1, 'first_name': 'Test'};
            default:
              return {'@type': 'ok'};
          }
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

  setUp(queries.clear);

  Future<void> openChat(
    WidgetTester tester, {
    required int chatId,
    required String title,
    bool isForum = false,
    Map<String, Object> extraPrefs = const {},
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'communitiesEnabled': false,
      ...extraPrefs,
    });
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    final accounts = AccountStore(prefs);
    final auth = AuthManager();
    final translation = TranslationController(prefs);
    addTearDown(theme.dispose);
    addTearDown(accounts.dispose);
    addTearDown(auth.dispose);
    addTearDown(translation.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<AccountStore>.value(value: accounts),
          ChangeNotifierProvider<AuthManager>.value(value: auth),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
        ],
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
      'chat': {
        '@type': 'chat',
        'id': chatId,
        'type': isForum
            ? {'@type': 'chatTypeSupergroup', 'supergroup_id': 9012}
            : {'@type': 'chatTypePrivate', 'user_id': _botUserId},
        'title': title,
        if (isForum) 'is_forum': true,
        'positions': [
          {
            '@type': 'chatPosition',
            'list': {'@type': 'chatListMain'},
            'order': 100,
          },
        ],
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();

    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChatView), findsOneWidget);
  }

  /// The strip is horizontally scrollable and now carries the tabs-position
  /// control at its leading edge: on a 390pt phone the last tab starts just
  /// past the viewport, so bring it into view before pressing it.
  Future<void> revealTopicTab(WidgetTester tester, int topicId) async {
    await tester.ensureVisible(find.byKey(ValueKey('topic-tab-$topicId')));
    await tester.pumpAndSettle();
  }

  testWidgets('long press opens an anchored pin/edit/close/delete menu', (
    tester,
  ) async {
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
    );

    await revealTopicTab(tester, 50);
    await tester.longPress(find.byKey(const ValueKey('topic-tab-50')));
    await tester.pumpAndSettle();

    // The narrow popup, not the wide topic bottom sheet.
    final menu = find.byKey(const ValueKey('app-anchored-menu'));
    expect(menu, findsOneWidget);
    expect(find.byKey(const ValueKey('topic-selector-list')), findsNothing);
    expect(find.byKey(const ValueKey('app-anchored-menu-pin')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-edit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('app-anchored-menu-close')),
      findsOneWidget,
    );
    expect(find.text('Close topic'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-delete')),
      findsOneWidget,
    );
    // No name header: the tab under the finger already names the topic.
    expect(
      find.descendant(of: menu, matching: find.text('Announcements')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-pin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-anchored-menu')), findsNothing);
    final pin = queries.lastWhere(
      (request) => request['@type'] == 'toggleForumTopicIsPinned',
    );
    expect(pin['chat_id'], _forumChatId);
    expect(pin['forum_topic_id'], 50);
    expect(pin['is_pinned'], true);

    // Closing a topic is the other management verb other clients offer here.
    await revealTopicTab(tester, 50);
    await tester.longPress(find.byKey(const ValueKey('topic-tab-50')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-close')));
    await tester.pumpAndSettle();
    final close = queries.lastWhere(
      (request) => request['@type'] == 'toggleForumTopicIsClosed',
    );
    expect(close['chat_id'], _forumChatId);
    expect(close['forum_topic_id'], 50);
    expect(close['is_closed'], true);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the bot topic tab menu moves the tabs to the side', (
    tester,
  ) async {
    TopicTabsPlacementStore.shared.resetForTesting();
    await openChat(tester, chatId: _botChatId, title: 'Topics Bot');

    final strip = find.byType(TopicTabStrip);
    final headerSide = tester.getRect(strip);
    await tester.longPress(find.byKey(const ValueKey('topic-tab-900')));
    await tester.pumpAndSettle();

    final move = find.byKey(const ValueKey('app-anchored-menu-tabs-position'));
    expect(move, findsOneWidget);
    // The first step of exteraless's cycle is the side dock.
    expect(find.text('Move tab bar to the side'), findsOneWidget);
    await tester.tap(move);
    await tester.pumpAndSettle();

    // The horizontal bar became the 64dp side column at the transcript's
    // left edge, and the choice stuck.
    expect(find.byType(TopicTabStrip), findsNothing);
    final sideBar = tester.getRect(find.byType(TopicTabsSideBar));
    expect(sideBar.width, 64);
    expect(sideBar.left, 0);
    expect(sideBar.top, greaterThanOrEqualTo(headerSide.top));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('mithka.topicTabsPlacement.v1.0.$_botChatId'),
      'side',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  // Only a bot topic chat offers the position control; a normal forum keeps
  // its server-defined top bar, even with a placement an older build stored.
  testWidgets('a forum chat keeps the tabs fixed at the top', (tester) async {
    TopicTabsPlacementStore.shared.resetForTesting();
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
      extraPrefs: {'mithka.topicTabsPlacement.v1.0.$_forumChatId': 'bottom'},
    );

    final strip = find.byType(TopicTabStrip);
    expect(strip, findsOneWidget);
    expect(
      tester.getRect(strip).top,
      lessThan(200),
      reason: 'a stored side/bottom placement must not move a forum\'s tabs',
    );
    expect(
      find.byKey(const ValueKey('topic-tabs-placement-toggle')),
      findsNothing,
    );

    await revealTopicTab(tester, 50);
    await tester.longPress(find.byKey(const ValueKey('topic-tab-50')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-anchored-menu')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-tabs-position')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the General topic only offers pin', (tester) async {
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
    );

    await tester.longPress(find.byKey(const ValueKey('topic-tab-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-anchored-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-anchored-menu-pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-anchored-menu-edit')), findsNothing);
    expect(find.byKey(const ValueKey('app-anchored-menu-close')), findsNothing);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-delete')),
      findsNothing,
    );

    await tester.tapAt(const Offset(10, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-anchored-menu')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  // A chat with a topics bot has no supergroup status, so can_manage_topics
  // never applies there; the bot's own `allows_users_to_create_topics` flag is
  // what makes pin/edit/delete operable. The tab menu used to gate on the
  // supergroup right alone and stayed silent in these chats.
  testWidgets('long press in the topic selector opens the same menu', (
    tester,
  ) async {
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
    );

    await tester.tap(find.byKey(const ValueKey('chatHeaderTopics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topic-selector-list')), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('topic-selector-row-50')));
    await tester.pumpAndSettle();

    final menu = find.byKey(const ValueKey('app-anchored-menu'));
    expect(menu, findsOneWidget);
    expect(find.byKey(const ValueKey('app-anchored-menu-pin')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-edit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('app-anchored-menu-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('app-anchored-menu-delete')),
      findsOneWidget,
    );
    // Same chrome as the tab menu: no topic name block.
    expect(
      find.descendant(of: menu, matching: find.text('Announcements')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-close')));
    await tester.pumpAndSettle();
    final close = queries.lastWhere(
      (request) => request['@type'] == 'toggleForumTopicIsClosed',
    );
    expect(close['chat_id'], _forumChatId);
    expect(close['forum_topic_id'], 50);
    expect(close['is_closed'], true);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  // The tab menu shared the default 8px control gap, which under a tab strip
  // reads as floating below the bar. A strip passes a tighter gap so the menu
  // hugs its bottom edge.
  testWidgets('the tab menu hugs the strip', (tester) async {
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
    );

    final tab = find.byKey(const ValueKey('topic-tab-50'));
    await revealTopicTab(tester, 50);
    final tabRect = tester.getRect(tab);
    await tester.longPress(tab);
    await tester.pumpAndSettle();

    final menuRect = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );
    expect(
      menuRect.top - tabRect.bottom,
      closeTo(AppSpacing.xs, 1),
      reason: 'the menu hugs the strip instead of floating below it',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  // A long press on a selector row used to anchor the menu to the row's box,
  // so it always opened at the row's own left edge and bottom — nowhere near a
  // finger pressed at the row's other end. The menu has to hang off the press
  // point, like every other pointer gesture in the app.
  testWidgets('the selector menu opens at the finger, not the row box', (
    tester,
  ) async {
    await openChat(
      tester,
      chatId: _forumChatId,
      title: 'Forum Group',
      isForum: true,
    );

    await tester.tap(find.byKey(const ValueKey('chatHeaderTopics')));
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('topic-selector-row-50'));
    final rowRect = tester.getRect(row);
    final press = Offset(rowRect.left + 40, rowRect.center.dy);
    await tester.longPressAt(press);
    await tester.pumpAndSettle();

    final menuRect = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final expectedLeft = press.dx.clamp(8.0, view.width - menuRect.width - 8);
    expect(menuRect.left, closeTo(expectedLeft, 0.5));
    // The placement works from the menu's metric estimate while the painted
    // card carries its own hairline borders, so allow the one-pixel seam.
    expect(
      menuRect.top,
      anyOf(
        closeTo(press.dy + 8, 2),
        closeTo(press.dy - 8 - menuRect.height, 2),
      ),
      reason: 'the menu hangs off the press point',
    );
    expect(
      (menuRect.left - rowRect.left).abs(),
      greaterThan(1),
      reason: 'the row box anchor would put the left edge at the row itself',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a bot topic chat can pin, edit and delete its topics', (
    tester,
  ) async {
    await openChat(tester, chatId: _botChatId, title: 'Topics Bot');

    await tester.longPress(find.byKey(const ValueKey('topic-tab-900')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-anchored-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-anchored-menu-pin')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-edit')),
      findsOneWidget,
    );
    // TDLib's close call is supergroup-only, so a bot chat never offers it.
    expect(find.byKey(const ValueKey('app-anchored-menu-close')), findsNothing);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-delete')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-pin')));
    await tester.pumpAndSettle();
    final pin = queries.lastWhere(
      (request) => request['@type'] == 'toggleForumTopicIsPinned',
    );
    expect(pin['chat_id'], _botChatId);
    expect(pin['forum_topic_id'], 900);
    expect(pin['is_pinned'], true);

    // Delete is offered without the supergroup creator probe, so it must also
    // reach the server from here.
    await tester.longPress(find.byKey(const ValueKey('topic-tab-900')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-confirm-dialog')), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    final delete = queries.lastWhere(
      (request) => request['@type'] == 'deleteForumTopic',
    );
    expect(delete['chat_id'], _botChatId);
    expect(delete['forum_topic_id'], 900);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
