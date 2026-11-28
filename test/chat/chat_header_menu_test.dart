//
//  chat_header_menu_test.dart
//
//  The chat header's `⋮` menu — exteraless's chat_menu_options column:
//
//  * every chat type carries it, so search has one predictable home;
//  * search leads the column and no longer holds a header glyph of its own;
//  * the column is the HEADER family (48px rows, 16sp labels, right edge under
//    the button) and stays visually distinct from the chat-info control;
//  * the commands exteraless puts there exist here too, gated by the same
//    rights: mute with durations, translation, linked chat, channel direct
//    messages, private calls, auto-delete, management, chat appearance, the
//    jump to the beginning, and the destructive tail (clear / leave / delete /
//    close topic);
//  * a topic chat's header action starts a topic (the title already opens the
//    topic list), and it disappears without the right to create one —
//    including a topics bot, whose permission is its own flag, never a
//    supergroup right.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/admin/chat_info_view.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chat/pinned_messages_view.dart';
import 'package:mithka/components/app_anchored_menu.dart';
import 'package:mithka/components/app_dialog.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _privateChatId = 4242;
const _peerUserId = 7001;
const _groupChatId = -1009101;
const _groupSupergroupId = 9101;
const _channelChatId = -1009202;
const _channelSupergroupId = 9202;
const _forumChatId = -1009303;
const _forumSupergroupId = 9303;
const _botChatId = 770011;
const _botUserId = 7701;
const _unjoinedChannelId = -1009404;
const _unjoinedChannelSupergroupId = 9404;
const _adminChatId = -1009606;
const _adminSupergroupId = 9606;
const _linkedChatId = -1009505;
const _directMessagesChatId = -1009507;

enum _Kind {
  privateChat,
  group,
  adminGroup,
  channel,
  forumCreator,
  forumMember,
  botTopics,
  botWithoutTopicRights,
  unjoinedChannel,
}

_Kind _kind = _Kind.privateChat;
bool _hasPinnedMessage = false;
bool _callsAvailable = true;
int _linkedChatIdOverride = 0;
int _directMessagesChatIdOverride = 0;
final _queries = <Map<String, dynamic>>[];

int get _chatId => switch (_kind) {
  _Kind.privateChat => _privateChatId,
  _Kind.group => _groupChatId,
  _Kind.adminGroup => _adminChatId,
  _Kind.channel => _channelChatId,
  _Kind.forumCreator || _Kind.forumMember => _forumChatId,
  _Kind.botTopics || _Kind.botWithoutTopicRights => _botChatId,
  _Kind.unjoinedChannel => _unjoinedChannelId,
};

Map<String, dynamic> _message(int id, {String text = 'hello'}) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1785862260 + id,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': _peerUserId},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
  },
};

Map<String, dynamic> _chat() {
  final (type, title) = switch (_kind) {
    _Kind.privateChat => (
      {'@type': 'chatTypePrivate', 'user_id': _peerUserId},
      'Friend',
    ),
    _Kind.group => (
      {
        '@type': 'chatTypeSupergroup',
        'supergroup_id': _groupSupergroupId,
        'is_channel': false,
      },
      'Team',
    ),
    _Kind.adminGroup => (
      {
        '@type': 'chatTypeSupergroup',
        'supergroup_id': _adminSupergroupId,
        'is_channel': false,
      },
      'Admin Team',
    ),
    _Kind.channel => (
      {
        '@type': 'chatTypeSupergroup',
        'supergroup_id': _channelSupergroupId,
        'is_channel': true,
      },
      'News',
    ),
    _Kind.forumCreator || _Kind.forumMember => (
      {
        '@type': 'chatTypeSupergroup',
        'supergroup_id': _forumSupergroupId,
        'is_channel': false,
      },
      'Forum',
    ),
    _Kind.botTopics || _Kind.botWithoutTopicRights => (
      {'@type': 'chatTypePrivate', 'user_id': _botUserId},
      'Topic Bot',
    ),
    _Kind.unjoinedChannel => (
      {
        '@type': 'chatTypeSupergroup',
        'supergroup_id': _unjoinedChannelSupergroupId,
        'is_channel': true,
      },
      'Unjoined News',
    ),
  };
  return {
    '@type': 'chat',
    'id': _chatId,
    'type': type,
    'title': title,
    'unread_count': 0,
    'last_read_inbox_message_id': 1,
    'can_be_deleted_only_for_self': true,
    'can_be_deleted_for_all_users': false,
    'permissions': {
      '@type': 'chatPermissions',
      'can_send_basic_messages': true,
    },
    if (_kind == _Kind.forumCreator || _kind == _Kind.forumMember)
      'is_forum': true,
  };
}

Map<String, dynamic> _topic(int id, String name, {bool isGeneral = false}) => {
  '@type': 'forumTopic',
  'info': {
    '@type': 'forumTopicInfo',
    'forum_topic_id': id,
    'name': name,
    if (isGeneral) 'is_general': true,
    'icon': {'@type': 'forumTopicIcon', 'color': 0x6FB9F0},
  },
  'unread_count': 0,
  'is_pinned': false,
  'is_closed': false,
  'last_message': {
    '@type': 'message',
    'id': 100 + id,
    'chat_id': _chatId,
    'date': 1785862260 + id,
    'is_outgoing': false,
    'sender_id': {'@type': 'messageSenderUser', 'user_id': 5},
    'content': {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': 'last in $name'},
    },
  },
};

Map<String, dynamic> _supergroup() {
  final status = switch (_kind) {
    _Kind.forumCreator => {'@type': 'chatMemberStatusCreator'},
    _Kind.adminGroup => {
      '@type': 'chatMemberStatusAdministrator',
      'rights': {'can_manage_chat': true, 'can_delete_messages': true},
    },
    _Kind.unjoinedChannel => {'@type': 'chatMemberStatusLeft'},
    _ => {'@type': 'chatMemberStatusMember'},
  };
  return {
    '@type': 'supergroup',
    'id': switch (_kind) {
      _Kind.adminGroup => _adminSupergroupId,
      _Kind.channel => _channelSupergroupId,
      _Kind.unjoinedChannel => _unjoinedChannelSupergroupId,
      _Kind.forumCreator || _Kind.forumMember => _forumSupergroupId,
      _ => _groupSupergroupId,
    },
    'is_forum': _kind == _Kind.forumCreator || _kind == _Kind.forumMember,
    'is_channel': _kind == _Kind.channel || _kind == _Kind.unjoinedChannel,
    'status': status,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          _queries.add(request);
          switch (request['@type']) {
            case 'getChat':
              return _chat();
            case 'getUser':
              if (request['user_id'] == _botUserId) {
                return {
                  '@type': 'user',
                  'id': _botUserId,
                  'first_name': 'Topic Bot',
                  'type': {
                    '@type': 'userTypeBot',
                    'has_topics': true,
                    'allows_users_to_create_topics': _kind == _Kind.botTopics,
                  },
                };
              }
              return {
                '@type': 'user',
                'id': request['user_id'] ?? _peerUserId,
                'first_name': 'Ann',
                'type': {'@type': 'userTypeRegular'},
              };
            case 'getMe':
              return {'@type': 'user', 'id': 1, 'first_name': 'Me'};
            case 'getUserFullInfo':
              return {
                '@type': 'userFullInfo',
                'can_be_called': _callsAvailable,
                'supports_video_calls': _callsAvailable,
              };
            case 'getSupergroup':
              return _supergroup();
            case 'getSupergroupFullInfo':
              return {
                '@type': 'supergroupFullInfo',
                'member_count': 8,
                'linked_chat_id': _linkedChatIdOverride,
                'direct_messages_chat_id': _directMessagesChatIdOverride,
              };
            case 'getBasicGroup':
              return {'@type': 'basicGroup', 'id': 1, 'member_count': 3};
            case 'getChatHistory':
              return {
                '@type': 'messages',
                'total_count': _kind == _Kind.unjoinedChannel ? 0 : 1,
                'messages': _kind == _Kind.unjoinedChannel
                    ? const <Object>[]
                    : [_message(1)],
              };
            case 'searchChatMessages':
              final filter = request['filter'];
              final pinned =
                  filter is Map &&
                  filter['@type'] == 'searchMessagesFilterPinned';
              return {
                '@type': 'foundChatMessages',
                'total_count': pinned && _hasPinnedMessage ? 1 : 0,
                'messages': pinned && _hasPinnedMessage
                    ? [_message(900, text: 'pinned note')]
                    : const <Object>[],
                'next_from_message_id': 0,
              };
            case 'getForumTopics':
              if (_kind == _Kind.botTopics ||
                  _kind == _Kind.botWithoutTopicRights) {
                return {
                  '@type': 'forumTopics',
                  'topics': [_topic(900, 'Releases')],
                  'total_count': 1,
                };
              }
              return {
                '@type': 'forumTopics',
                'topics': [
                  _topic(1, 'General', isGeneral: true),
                  _topic(50, 'Announcements'),
                ],
                'total_count': 2,
              };
            case 'getForumTopic':
              return _topic(50, 'Announcements');
            case 'getForumTopicHistory':
              return {
                '@type': 'messages',
                'total_count': 2,
                'messages': [_message(52), _message(53)],
              };
            case 'getOption':
              return {'@type': 'optionValueInteger', 'value': '1024'};
            case 'getCountries':
              return {'@type': 'countries', 'countries': const []};
            default:
              return {'@type': 'ok'};
          }
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': 'connectionStateReady'},
    });
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  setUp(() {
    _kind = _Kind.privateChat;
    _hasPinnedMessage = false;
    _callsAvailable = true;
    _linkedChatIdOverride = 0;
    _directMessagesChatIdOverride = 0;
    _queries.clear();
  });

  Future<void> openChat(
    WidgetTester tester, {
    int? forumTopicId,
    VoidCallback? onBack,
    Size size = const Size(390, 844),
    Map<String, Object> initialPrefs = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(initialPrefs);
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    final locale = AppLocaleController(prefs);
    final accounts = AccountStore(prefs);
    final auth = AuthManager();
    final translation = TranslationController(prefs);
    final drawer = dc.DrawerController();
    addTearDown(theme.dispose);
    addTearDown(locale.dispose);
    addTearDown(accounts.dispose);
    addTearDown(auth.dispose);
    addTearDown(translation.dispose);
    addTearDown(drawer.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<AppLocaleController>.value(value: locale),
          ChangeNotifierProvider<AccountStore>.value(value: accounts),
          ChangeNotifierProvider<AuthManager>.value(value: auth),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
          ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
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
          theme: ThemeData(
            brightness: Brightness.light,
            extensions: [AppColors.light],
          ),
          home: ChatView(
            chatId: _chatId,
            title: 'Chat',
            forumTopicId: forumTopicId,
            onBack: onBack,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('chatHeaderMenu')));
    await tester.pumpAndSettle();
  }

  Future<void> closeChat(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }

  Finder row(String key) => find.byKey(ValueKey('app-anchored-menu-$key'));

  AppIconData headerIcon(WidgetTester tester, String key) => tester
      .widget<AppIcon>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(AppIcon),
        ),
      )
      .icon;

  testWidgets('every chat type carries the menu, search and a details title', (
    tester,
  ) async {
    for (final kind in _Kind.values) {
      if (kind == _Kind.unjoinedChannel) continue; // its own case below
      _kind = kind;
      await openChat(tester);

      expect(
        find.byKey(const ValueKey('chatHeaderMenu')),
        findsOneWidget,
        reason: '$kind must offer the chat menu',
      );
      expect(
        find.byKey(const ValueKey('chatHeaderSearch')),
        findsOneWidget,
        reason: '$kind keeps its own search control beside the menu',
      );
      // The details door is the title now; the old info button is gone.
      expect(find.byKey(const ValueKey('chatHeaderInfo')), findsNothing);
      expect(find.byKey(const ValueKey('chatHeaderTitle')), findsOneWidget);

      await closeChat(tester);
    }
  });

  testWidgets('search leads the menu and opens the in-chat search', (
    tester,
  ) async {
    await openChat(tester);
    await openMenu(tester);

    expect(find.text('Search in chat'), findsOneWidget);
    final search = row('search');
    expect(search, findsOneWidget);
    final mute = row('mute');
    expect(mute, findsOneWidget);
    expect(
      tester.getTopLeft(search).dy,
      lessThan(tester.getTopLeft(mute).dy),
      reason: 'search is the first option',
    );

    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSearchField')), findsOneWidget);

    await closeChat(tester);
  });

  testWidgets('the chat menu draws the header family, not a tab column', (
    tester,
  ) async {
    await openChat(tester);
    final button = tester.getRect(find.byKey(const ValueKey('chatHeaderMenu')));
    await openMenu(tester);

    final menu = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );
    expect(
      menu.right,
      closeTo(button.right, 1),
      reason: 'the column hangs off its own button, right edge on right edge',
    );
    expect(menu.top, closeTo(button.bottom + AppSpacing.xs, 1));
    expect(menu.width, greaterThanOrEqualTo(196));

    final search = row('search');
    expect(tester.getSize(search).height, 48);
    final label = tester.widget<Text>(
      find.descendant(of: search, matching: find.byType(Text)),
    );
    expect(label.style?.fontSize, AppTextSize.bodyLarge);

    // The compact tab column keeps its own 36px row; the two families must
    // not collapse into one.
    expect(tester.getSize(search).height, isNot(appAnchoredMenuRowHeight));

    await closeChat(tester);
  });

  testWidgets('the menu button is the action-bar bars glyph', (tester) async {
    await openChat(tester);

    expect(headerIcon(tester, 'chatHeaderMenu'), HeroAppIcons.bars);

    await closeChat(tester);
  });

  testWidgets('a topic chat orders the topic list, new topic, then the menu', (
    tester,
  ) async {
    _kind = _Kind.forumCreator;
    await openChat(tester);

    double centreX(String key) =>
        tester.getCenter(find.byKey(ValueKey(key))).dx;
    final topics = centreX('chatHeaderTopics');
    final newTopic = centreX('chatHeaderNewTopic');
    final menu = centreX('chatHeaderMenu');
    expect(topics, lessThan(newTopic), reason: 'topic list sits left of +');
    expect(newTopic, lessThan(menu), reason: '+ sits left of the menu');
    expect(
      tester.getRect(find.byKey(const ValueKey('chatHeaderMenu'))).right,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('chatHeaderNewTopic'))).right,
      ),
      reason: 'the menu is the rightmost control',
    );

    await closeChat(tester);
  });

  testWidgets('the title opens the details page for a topic chat', (
    tester,
  ) async {
    _kind = _Kind.forumCreator;
    await openChat(tester);

    await tester.tap(find.byKey(const ValueKey('chatHeaderTitle')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatInfoView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('topic-selector-list')),
      findsNothing,
      reason: 'the title is the details door now, not the topic list',
    );

    // Leave the page before the harness replaces the tree: a route popped
    // while its host is being torn down lays out against a vanishing width.
    Navigator.of(tester.element(find.byType(ChatInfoView))).pop();
    await tester.pumpAndSettle();

    await closeChat(tester);
  });

  testWidgets('a private chat offers exteraless\'s chat commands in blocks', (
    tester,
  ) async {
    await openChat(tester);
    await openMenu(tester);

    // Chat commands block.
    expect(row('mute'), findsOneWidget);
    expect(row('call'), findsOneWidget);
    expect(row('video-call'), findsOneWidget);
    expect(row('auto-delete'), findsOneWidget);
    // The appearance rows live in the details page, not here.
    expect(row('theme'), findsNothing);
    expect(row('wallpaper'), findsNothing);
    // Transcript block.
    expect(row('to-beginning'), findsOneWidget);
    expect(row('go-to-message'), findsOneWidget);
    // Destructive block: a private chat can be deleted, never left, and has
    // no group management or linked chat.
    expect(row('clear-history'), findsOneWidget);
    expect(row('delete-chat'), findsOneWidget);
    expect(row('leave'), findsNothing);
    expect(row('manage'), findsNothing);
    expect(row('linked-chat'), findsNothing);
    expect(row('direct-messages'), findsNothing);
    expect(row('close-topic'), findsNothing);

    // The commands sit between search and the destructive tail, in order.
    final searchY = tester.getTopLeft(row('search')).dy;
    final muteY = tester.getTopLeft(row('mute')).dy;
    final clearY = tester.getTopLeft(row('clear-history')).dy;
    final deleteY = tester.getTopLeft(row('delete-chat')).dy;
    expect(muteY, greaterThan(searchY));
    expect(clearY, greaterThan(muteY));
    expect(deleteY, greaterThan(clearY));

    // exteraless splits the column with one gap per block: 9px (a hairline
    // plus breathing room) where a block starts, nothing between its rows.
    double gapAfter(String above, String below) =>
        tester.getTopLeft(row(below)).dy - tester.getBottomLeft(row(above)).dy;
    expect(gapAfter('search', 'mute'), appAnchoredMenuSectionGap);
    expect(gapAfter('call', 'video-call'), 0);
    expect(gapAfter('to-beginning', 'go-to-message'), 0);
    expect(gapAfter('clear-history', 'delete-chat'), 0);

    await closeChat(tester);
  });

  testWidgets('a channel links its discussion group and direct messages', (
    tester,
  ) async {
    _kind = _Kind.channel;
    _linkedChatIdOverride = _linkedChatId;
    _directMessagesChatIdOverride = _directMessagesChatId;
    await openChat(tester);
    await openMenu(tester);

    expect(row('linked-chat'), findsOneWidget);
    expect(row('direct-messages'), findsOneWidget);
    // A member channel can be left, not deleted, and the discussion row is
    // named for the channel side.
    expect(row('leave'), findsOneWidget);
    expect(row('delete-chat'), findsNothing);
    expect(find.text('Discussion group'), findsOneWidget);

    await closeChat(tester);
  });

  testWidgets('only an administrator gets the management row', (tester) async {
    _kind = _Kind.adminGroup;
    await openChat(tester);
    await openMenu(tester);
    expect(row('manage'), findsOneWidget);
    expect(find.text('Manage group'), findsOneWidget);
    await closeChat(tester);

    _kind = _Kind.group;
    await openChat(tester);
    await openMenu(tester);
    expect(row('manage'), findsNothing);
    await closeChat(tester);
  });

  testWidgets('mute opens its durations as a submenu of the same card', (
    tester,
  ) async {
    await openChat(tester);
    await openMenu(tester);
    expect(find.text('Mute'), findsOneWidget);
    final card = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );

    await tester.tap(row('mute'));
    await tester.pumpAndSettle();
    // exteraless's durations, inside the menu card rather than a sheet.
    expect(find.text('For 1 hour'), findsOneWidget);
    expect(find.text('For 8 hours'), findsOneWidget);
    expect(find.text('For 2 days'), findsOneWidget);
    expect(find.text('Forever'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-anchored-menu-back')),
      findsOneWidget,
    );
    // exteraless's submenu items are text-only: the back chevron is the only
    // glyph left in the card.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('app-anchored-menu')),
        matching: find.byType(AppIcon),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('app-anchored-menu-back')),
        matching: find.text('Mute'),
      ),
      findsOneWidget,
      reason: 'the back row names the row the submenu belongs to',
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('app-anchored-menu'))).left,
      card.left,
      reason: 'the submenu keeps the card where it opened',
    );
    expect(
      find.text('Search in chat'),
      findsNothing,
      reason: 'the submenu replaces the column it came from',
    );

    // Back returns to the column without closing the menu.
    await tester.tap(find.byKey(const ValueKey('app-anchored-menu-back')));
    await tester.pumpAndSettle();
    expect(row('search'), findsOneWidget);
    expect(find.text('For 8 hours'), findsNothing);
    await tester.tap(row('mute'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('app-anchored-menu-mute-28800')),
    );
    await tester.pumpAndSettle();
    final mute = _queries.lastWhere(
      (request) => request['@type'] == 'setChatNotificationSettings',
    );
    expect(
      (mute['notification_settings'] as Map<String, dynamic>)['mute_for'],
      28800,
    );

    // The row names what the next tap does, exteraless's state-paired label.
    await openMenu(tester);
    expect(find.text('Unmute'), findsOneWidget);
    await tester.tap(row('mute'));
    await tester.pumpAndSettle();
    final unmute = _queries.lastWhere(
      (request) => request['@type'] == 'setChatNotificationSettings',
    );
    expect(
      (unmute['notification_settings'] as Map<String, dynamic>)['mute_for'],
      0,
    );
    // An already-muted chat unmutes straight away — no sheet.
    expect(find.text('For 8 hours'), findsNothing);

    await closeChat(tester);
  });

  testWidgets('auto-delete picks a timer from its own submenu', (tester) async {
    await openChat(tester);
    await openMenu(tester);
    final card = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );

    await tester.tap(row('auto-delete'));
    await tester.pumpAndSettle();
    // The same card as mute's: back row, then the four timers, no glyphs.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('app-anchored-menu-back')),
        matching: find.text('Auto-delete messages'),
      ),
      findsOneWidget,
    );
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('1 day'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('1 month'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('app-anchored-menu')),
        matching: find.byType(AppIcon),
      ),
      findsOneWidget,
      reason: 'only the back chevron stays in the card',
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('app-anchored-menu'))).left,
      card.left,
    );

    await tester.tap(
      find.byKey(const ValueKey('app-anchored-menu-auto-delete-604800')),
    );
    await tester.pumpAndSettle();
    final request = _queries.lastWhere(
      (response) => response['@type'] == 'setChatMessageAutoDeleteTime',
    );
    expect(request['chat_id'], _privateChatId);
    expect(
      (request['message_auto_delete_time'] as Map<String, dynamic>)['time'],
      604800,
    );

    await closeChat(tester);
  });

  testWidgets('clear history asks twice, then clears for this account', (
    tester,
  ) async {
    await openChat(tester);
    await openMenu(tester);

    await tester.tap(row('clear-history'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-confirm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();

    final request = _queries.lastWhere(
      (response) => response['@type'] == 'deleteChatHistory',
    );
    expect(request['chat_id'], _privateChatId);
    expect(request['revoke'], false);
    expect(
      request['remove_from_chat_list'],
      false,
      reason: 'clearing history keeps the chat in the list',
    );

    await closeChat(tester);
  });

  testWidgets('leaving a group asks twice, sends leaveChat and closes', (
    tester,
  ) async {
    _kind = _Kind.group;
    var closed = 0;
    await openChat(tester, onBack: () => closed++);
    await openMenu(tester);

    await tester.tap(row('leave'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();

    expect(
      _queries.where((request) => request['@type'] == 'leaveChat'),
      isNotEmpty,
    );
    expect(closed, 1, reason: 'the transcript closes after leaving');

    await closeChat(tester);
  });

  testWidgets('deleting a private chat goes through the scope dialog', (
    tester,
  ) async {
    var closed = 0;
    await openChat(tester, onBack: () => closed++);
    await openMenu(tester);

    await tester.tap(row('delete-chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-delete-scope-self')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();

    final request = _queries.lastWhere(
      (response) => response['@type'] == 'deleteChatHistory',
    );
    expect(request['chat_id'], _privateChatId);
    expect(request['remove_from_chat_list'], true);
    expect(closed, 1);

    await closeChat(tester);
  });

  testWidgets('to the beginning inside a topic targets the topic message', (
    tester,
  ) async {
    _kind = _Kind.forumCreator;
    await openChat(tester, forumTopicId: 50);
    await openMenu(tester);

    await tester.tap(row('to-beginning'));
    await tester.pumpAndSettle();

    final request = _queries.lastWhere(
      (response) => response['@type'] == 'getForumTopicHistory',
    );
    expect(
      request['from_message_id'],
      50,
      reason: 'a topic id is its first message id; chat id 1 is unreachable',
    );
    expect(request['forum_topic_id'], 50);

    await closeChat(tester);
  });

  testWidgets('go to message jumps to the id the user types', (tester) async {
    await openChat(tester);
    await openMenu(tester);

    await tester.tap(row('go-to-message'));
    await tester.pumpAndSettle();
    expect(find.text('Go to message'), findsWidgets);
    expect(find.text('Enter message ID'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AppDialogSurface),
        matching: find.byType(TextField),
      ),
      '777',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final request = _queries.lastWhere(
      (response) =>
          response['@type'] == 'getMessage' && response['message_id'] == 777,
    );
    expect(request['chat_id'], _privateChatId);

    await closeChat(tester);
  });

  testWidgets('a forum topic offers closing it, and no topics list row', (
    tester,
  ) async {
    _kind = _Kind.forumCreator;
    await openChat(tester, forumTopicId: 50);
    await openMenu(tester);

    expect(row('close-topic'), findsOneWidget);
    expect(find.text('Close topic'), findsOneWidget);

    await tester.tap(row('close-topic'));
    await tester.pumpAndSettle();
    final request = _queries.lastWhere(
      (response) => response['@type'] == 'toggleForumTopicIsClosed',
    );
    expect(request['forum_topic_id'], 50);
    expect(request['is_closed'], true);

    await closeChat(tester);
  });

  testWidgets('a long column stays inside the window and scrolls', (
    tester,
  ) async {
    _kind = _Kind.channel;
    _linkedChatIdOverride = _linkedChatId;
    _directMessagesChatIdOverride = _directMessagesChatId;
    // A short window: the admin channel's column cannot fit even without the
    // management block, so it has to cap its height and scroll.
    await openChat(tester, size: const Size(390, 420));

    final button = tester.getRect(find.byKey(const ValueKey('chatHeaderMenu')));
    await openMenu(tester);

    final menu = tester.getRect(
      find.byKey(const ValueKey('app-anchored-menu')),
    );
    expect(menu.height, lessThanOrEqualTo(420 - 2 * 8));
    expect(menu.top, greaterThanOrEqualTo(8));
    expect(menu.bottom, lessThanOrEqualTo(420 - 8));
    expect(
      find.byKey(const ValueKey('app-anchored-menu-scroll')),
      findsOneWidget,
    );
    // The column still hangs off its button.
    expect(menu.right, closeTo(button.right, 1));

    await closeChat(tester);
  });

  testWidgets('a forum creator starts a topic from the header', (tester) async {
    _kind = _Kind.forumCreator;
    await openChat(tester);

    // The list has its own header control; the header's second action starts
    // a topic.
    expect(find.byKey(const ValueKey('chatHeaderTopics')), findsOneWidget);
    final newTopic = find.byKey(const ValueKey('chatHeaderNewTopic'));
    expect(newTopic, findsOneWidget);
    expect(headerIcon(tester, 'chatHeaderNewTopic'), HeroAppIcons.plus);

    await tester.tap(newTopic);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-draft-name')),
      'Release notes',
    );
    await tester.tap(find.byKey(const ValueKey('topic-draft-save')));
    await tester.pumpAndSettle();

    final create = _queries.lastWhere(
      (request) => request['@type'] == 'createForumTopic',
    );
    expect(create['chat_id'], _forumChatId);
    expect(create['name'], 'Release notes');

    await closeChat(tester);
  });

  testWidgets('a topics bot gets the new-topic button from its own flag', (
    tester,
  ) async {
    _kind = _Kind.botTopics;
    await openChat(tester);

    expect(find.byKey(const ValueKey('chatHeaderNewTopic')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chatHeaderNewTopic')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-draft-name')),
      'New subject',
    );
    await tester.tap(find.byKey(const ValueKey('topic-draft-save')));
    await tester.pumpAndSettle();

    final create = _queries.lastWhere(
      (request) => request['@type'] == 'createForumTopic',
    );
    expect(create['chat_id'], _botChatId);

    await closeChat(tester);
  });

  testWidgets('no create right, no new-topic button', (tester) async {
    for (final kind in [_Kind.forumMember, _Kind.botWithoutTopicRights]) {
      _kind = kind;
      await openChat(tester);

      expect(
        find.byKey(const ValueKey('chatHeaderNewTopic')),
        findsNothing,
        reason: '$kind has no right to start a topic',
      );
      // The topic list is still reachable — through its own header control.
      expect(find.byKey(const ValueKey('chatHeaderTopics')), findsOneWidget);

      await closeChat(tester);
    }
  });

  testWidgets('the pinned row exists only when a message is pinned', (
    tester,
  ) async {
    await openChat(tester);
    await openMenu(tester);
    expect(row('pinned-messages'), findsNothing);
    await tester.tapAt(const Offset(10, 800));
    await tester.pumpAndSettle();
    await closeChat(tester);

    _hasPinnedMessage = true;
    await openChat(tester);
    await openMenu(tester);
    final pinned = row('pinned-messages');
    expect(pinned, findsOneWidget);
    expect(find.text('Pinned Messages'), findsOneWidget);

    await tester.tap(pinned);
    await tester.pumpAndSettle();
    expect(find.byType(PinnedMessagesView), findsOneWidget);

    await closeChat(tester);
  });

  testWidgets('a long press on the pinned bar opens all pinned messages', (
    tester,
  ) async {
    _hasPinnedMessage = true;
    await openChat(tester);

    final bar = find.byKey(const ValueKey('chatPinnedBar'));
    expect(bar, findsOneWidget);
    await tester.longPress(bar);
    await tester.pumpAndSettle();

    expect(find.byType(PinnedMessagesView), findsOneWidget);

    await closeChat(tester);
  });

  testWidgets('pinning a group message asks whether to notify everyone', (
    tester,
  ) async {
    _kind = _Kind.group;
    await openChat(tester);

    await tester.longPress(find.text('hello', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-confirm-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-dialog-notify')), findsOneWidget);

    _queries.clear();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();

    final pin = _queries.where((q) => q['@type'] == 'pinChatMessage');
    expect(pin, isNotEmpty);
    expect(pin.last['disable_notification'], isFalse);
    expect(pin.last['only_for_self'], isFalse);

    await closeChat(tester);
  });

  testWidgets('a private-chat pin stays on this account by default', (
    tester,
  ) async {
    await openChat(tester);

    await tester.longPress(find.text('hello', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pin-dialog-also-for')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-dialog-notify')), findsNothing);

    _queries.clear();
    await tester.tap(find.byKey(const ValueKey('app-confirm-accept')));
    await tester.pumpAndSettle();

    final pin = _queries.where((q) => q['@type'] == 'pinChatMessage');
    expect(pin, isNotEmpty);
    expect(pin.last['only_for_self'], isTrue);
    expect(pin.last['disable_notification'], isTrue);

    await closeChat(tester);
  });

  testWidgets('a double tap runs the configured action, and none disables it', (
    tester,
  ) async {
    await openChat(
      tester,
      initialPrefs: const {'doubleTapAction.incoming.v1': 'reply'},
    );

    await tester.tap(find.text('hello', findRichText: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('hello', findRichText: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composerReplyBanner')), findsOneWidget);
    await closeChat(tester);

    await openChat(
      tester,
      initialPrefs: const {'doubleTapAction.incoming.v1': 'none'},
    );
    await tester.tap(find.text('hello', findRichText: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('hello', findRichText: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composerReplyBanner')), findsNothing);
    await closeChat(tester);
  });

  testWidgets('a join screen with nothing to act on has no menu button', (
    tester,
  ) async {
    _kind = _Kind.unjoinedChannel;
    await openChat(tester);

    expect(find.byKey(const ValueKey('chatHeaderMenu')), findsNothing);
    // Search keeps its own header slot the way it always had one; only the
    // menu disappears when it would be empty.
    expect(find.byKey(const ValueKey('chatHeaderSearch')), findsOneWidget);

    await closeChat(tester);
  });
}
