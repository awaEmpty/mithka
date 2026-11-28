//
//  pinned_messages_view_test.dart
//
//  The long-press pinned browser is the reference client's MODE_PINNED
//  transcript: bubbles, a "N Pinned Messages" title, a bottom bar that unpins
//  everything (or hides the bar), a tap that closes the page with the message
//  to jump to, and the long-press message menu.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/chat/pinned_messages_view.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n_fixtures.dart';

const _chatId = -1005001;
const _senderId = 7001;
const _supergroupId = 5001;

/// How this account sits in the chat under test.
enum _Seat {
  /// A plain member of a supergroup whose default permissions allow pinning.
  memberCanPin,

  /// An administrator: `chat.permissions` says nothing about admins, only
  /// `rights.can_pin_messages` does.
  adminCanPin,

  /// A plain member of a group where members may not pin.
  memberCannotPin,

  /// A private chat, whose answer is `userFullInfo.can_pin_message`.
  privateCanPin,
}

Map<String, dynamic> _message(int id, String text) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1785862260 + id,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': _senderId},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
  },
};

Map<String, dynamic> _chat(_Seat seat) {
  final permissions = switch (seat) {
    _Seat.memberCanPin || _Seat.privateCanPin => true,
    _Seat.adminCanPin || _Seat.memberCannotPin => false,
  };
  return {
    '@type': 'chat',
    'id': _chatId,
    'type': seat == _Seat.privateCanPin
        ? {'@type': 'chatTypePrivate', 'user_id': _senderId}
        : {
            '@type': 'chatTypeSupergroup',
            'supergroup_id': _supergroupId,
            'is_channel': false,
          },
    'title': 'Team',
    'permissions': {
      '@type': 'chatPermissions',
      'can_pin_messages': permissions,
    },
  };
}

Map<String, dynamic> _supergroup(_Seat seat) => {
  '@type': 'supergroup',
  'id': _supergroupId,
  'status': seat == _Seat.adminCanPin
      ? {
          '@type': 'chatMemberStatusAdministrator',
          'rights': {'can_pin_messages': true},
        }
      : {'@type': 'chatMemberStatusMember'},
};

void main() {
  late StreamController<Map<String, dynamic>> updates;
  final queries = <Map<String, dynamic>>[];
  var seat = _Seat.memberCanPin;
  var configured = false;

  setUpAll(() {
    L10nFixtures.load().install();
    updates = StreamController<Map<String, dynamic>>.broadcast();
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  void installTransport(_Seat value) {
    queries.clear();
    seat = value;
    if (configured) return;
    configured = true;
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          queries.add(request);
          switch (request['@type']) {
            case 'searchChatMessages':
              return {
                '@type': 'messages',
                'total_count': 2,
                'messages': [
                  _message(12, 'second pinned'),
                  _message(11, 'first pinned'),
                ],
              };
            case 'getChat':
              return _chat(seat);
            case 'getSupergroup':
              return _supergroup(seat);
            case 'getUserFullInfo':
              return {'@type': 'userFullInfo', 'can_pin_message': true};
            case 'getMe':
              return {'@type': 'user', 'id': 1, 'first_name': 'Me'};
            case 'getUser':
              return {
                '@type': 'user',
                'id': _senderId,
                'first_name': 'Ann',
                'type': {'@type': 'userTypeRegular'},
              };
            default:
              return {'@type': 'ok'};
          }
        },
        send: (request) async {},
        updates: updates.stream,
      ),
    );
  }

  Future<Object? Function()> pumpPage(
    WidgetTester tester, {
    _Seat as = _Seat.memberCanPin,
    ValueChanged<ChatMessage>? onReply,
    ValueChanged<ChatMessage>? onForward,
  }) async {
    installTransport(as);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    Object? result;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: GestureDetector(
                  onTap: () async {
                    result = await Navigator.of(context).push<Object>(
                      MaterialPageRoute<Object>(
                        builder: (_) => PinnedMessagesView(
                          chatId: _chatId,
                          title: 'Team',
                          onReply: onReply,
                          onForward: onForward,
                        ),
                      ),
                    );
                  },
                  child: const Text('open', key: ValueKey('openPinned')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('openPinned')));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('the pinned list is a transcript with a count and an unpin bar', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('2 Pinned Messages'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(find.text('Unpin all Messages'), findsOneWidget);
    expect(find.byType(TimeSeparator), findsOneWidget);
  });

  testWidgets('a tap closes the list with the message to jump to', (
    tester,
  ) async {
    final result = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('pinnedMessage-12')));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedMessagesView), findsNothing);
    expect(result(), 12, reason: 'the chat scrolls to the tapped message');
  });

  testWidgets('an administrator may unpin even though members may not', (
    tester,
  ) async {
    await pumpPage(tester, as: _Seat.adminCanPin);
    expect(
      find.text('Unpin all Messages'),
      findsOneWidget,
      reason: 'chat.permissions is the member default, not the admin right',
    );
  });

  testWidgets('a private chat follows can_pin_message', (tester) async {
    await pumpPage(tester, as: _Seat.privateCanPin);
    expect(find.text('Unpin all Messages'), findsOneWidget);
  });

  testWidgets('an account that may not pin gets the hide action', (
    tester,
  ) async {
    final result = await pumpPage(tester, as: _Seat.memberCannotPin);
    expect(find.text('Hide pinned Messages'), findsOneWidget);
    expect(find.text('Unpin all Messages'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pinnedMessagesBottomAction')));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedMessagesView), findsNothing);
    expect(result(), PinnedMessagesExit.hide);
  });

  testWidgets('unpinning calls TDLib and closes the list', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('pinnedMessagesBottomAction')));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedMessagesView), findsNothing);
    expect(
      queries.any((q) => q['@type'] == 'unpinAllChatMessages'),
      isTrue,
      reason: 'the bottom bar must unpin every message, not just hide the bar',
    );
  });

  testWidgets('a long press opens the message menu', (tester) async {
    ChatMessage? replied;
    await pumpPage(
      tester,
      onReply: (message) => replied = message,
      onForward: (_) {},
    );
    await tester.longPress(find.byKey(const ValueKey('pinnedMessage-12')));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('Unpin'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedMessagesView), findsNothing);
    expect(replied?.id, 12, reason: 'the chat arms its composer for the row');
  });

  testWidgets('unpinning one row drops it from the list', (tester) async {
    await pumpPage(tester);
    await tester.longPress(find.byKey(const ValueKey('pinnedMessage-12')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();

    expect(
      queries.any(
        (q) => q['@type'] == 'unpinChatMessage' && q['message_id'] == 12,
      ),
      isTrue,
    );
    expect(find.byKey(const ValueKey('pinnedMessage-12')), findsNothing);
    expect(find.text('1 Pinned Message'), findsOneWidget);
  });
}
