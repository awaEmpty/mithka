//
//  The comments sheet reads like exteraless's thread chat: a comment that
//  answers the post itself shows no reply marker, while a reply to another
//  comment keeps its marker and jumps inside the sheet (never out to the
//  discussion group).
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_replies_sheet.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n_fixtures.dart';

const _channelChatId = -100777;
const _commentsChatId = -100999;

Map<String, dynamic> _message({
  required int id,
  required int chatId,
  required String text,
  int? replyToId,
  int? replyToChatId,
}) => {
  '@type': 'message',
  'id': id,
  'chat_id': chatId,
  'date': 1700000000 + id,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 800},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
  },
  if (replyToId != null)
    'reply_to': {
      '@type': 'messageReplyToMessage',
      'message_id': replyToId,
      'chat_id': replyToChatId ?? chatId,
    },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => L10nFixtures.load().install());

  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
    SharedPreferences.setMockInitialValues(const {});
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async {
          switch (request['@type']) {
            case 'getMessageProperties':
              return <String, dynamic>{
                '@type': 'messageProperties',
                'can_be_replied': true,
                'can_get_message_thread': true,
              };
            case 'getMessageThread':
              return <String, dynamic>{
                'chat_id': _commentsChatId,
                'message_thread_id': 500,
              };
            case 'getChat':
              return <String, dynamic>{
                '@type': 'chat',
                'id': request['chat_id'],
                'title': 'Comments',
                'permissions': {'can_send_basic_messages': true},
              };
            case 'getMessageThreadHistory':
              return <String, dynamic>{
                '@type': 'messages',
                'total_count': 3,
                'messages': [
                  _message(
                    id: 501,
                    chatId: _commentsChatId,
                    text: 'first comment',
                    replyToId: 500,
                    replyToChatId: _commentsChatId,
                  ),
                  _message(
                    id: 502,
                    chatId: _commentsChatId,
                    text: 'second comment',
                    replyToId: 501,
                    replyToChatId: _commentsChatId,
                  ),
                  _message(
                    id: 503,
                    chatId: _commentsChatId,
                    text: 'third comment',
                    replyToId: 480,
                    replyToChatId: _commentsChatId,
                  ),
                ],
              };
            case 'getMessages':
              return <String, dynamic>{
                '@type': 'messages',
                'total_count': 2,
                'messages': [
                  _message(id: 500, chatId: _commentsChatId, text: 'the post'),
                  _message(
                    id: 480,
                    chatId: _commentsChatId,
                    text: 'older comment',
                  ),
                ],
              };
            case 'getUser':
              return <String, dynamic>{
                '@type': 'user',
                'id': 800,
                'first_name': 'Ada',
                'last_name': 'Lovelace',
                'usernames': {'active_usernames': <String>[]},
              };
            default:
              return <String, dynamic>{'@type': 'ok'};
          }
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  var viewedAway = false;

  Future<void> pumpSheet(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(const {});
    viewedAway = false;
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageRepliesSheet(
                  context: context,
                  chatId: _channelChatId,
                  message: ChatMessage(
                    id: 10,
                    isOutgoing: false,
                    text: 'the post',
                    date: 1700000000,
                    chatId: _channelChatId,
                  ),
                  peerTitle: 'Channel',
                  onViewInChat: (_) => viewedAway = true,
                ),
                child: const Text('open comments'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open comments'));
    await tester.pumpAndSettle();
  }

  testWidgets('a reply to the post shows no marker in the comments', (
    tester,
  ) async {
    await pumpSheet(tester);
    final onPost = find.byKey(const ValueKey('messageRepliesSheetMessage-501'));
    expect(onPost, findsOneWidget);
    expect(
      find.descendant(
        of: onPost,
        matching: find.byKey(const ValueKey('messageReplyQuote')),
      ),
      findsNothing,
      reason: 'the thread root is implicit in a comments view',
    );
    // A reply to another comment keeps its marker.
    final onComment = find.byKey(
      const ValueKey('messageRepliesSheetMessage-502'),
    );
    expect(
      find.descendant(
        of: onComment,
        matching: find.byKey(const ValueKey('messageReplyQuote')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a reply to an older comment jumps inside the sheet', (
    tester,
  ) async {
    await pumpSheet(tester);
    final row = find.byKey(const ValueKey('messageRepliesSheetMessage-503'));
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('messageReplyOpenOriginal')),
      ),
    );
    await tester.pumpAndSettle();

    // Still in the comments sheet — not pushed into the discussion group.
    expect(
      viewedAway,
      isFalse,
      reason: 'an in-sheet reply jump must not open the discussion chat',
    );
    expect(
      find.byKey(const ValueKey('messageRepliesSheetMessage-480')),
      findsOneWidget,
      reason: 'the target comment is fetched and revealed in place',
    );
  });
}
