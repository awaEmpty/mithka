//
//  sticker_reply_pipeline_test.dart
//
//  End-to-end: TDLib JSON -> ChatViewModel -> ChatView transcript. A sticker
//  that answers a message must show the reply panel above the sticker, and a
//  quoted media-only message (a sticker) must still name what it is instead of
//  rendering an empty quote.
//

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = 880011;

late String _pngPath;

Map<String, dynamic> _file(int id) => {
  '@type': 'file',
  'id': id,
  'size': 0,
  'expected_size': 0,
  'local': {
    '@type': 'localFile',
    'path': _pngPath,
    'can_be_downloaded': true,
    'is_downloading_completed': true,
  },
  'remote': {'@type': 'remoteFile', 'id': 'x$id', 'is_uploading_active': false},
};

Map<String, dynamic> _stickerContent(int stickerId) => {
  '@type': 'messageSticker',
  'sticker': {
    '@type': 'sticker',
    'id': stickerId,
    'set_id': 0,
    'width': 512,
    'height': 512,
    'emoji': '👍',
    'format': {'@type': 'stickerFormatWebp'},
    'full_type': {'@type': 'stickerFullTypeRegular'},
    'thumbnail': {
      '@type': 'thumbnail',
      'format': {'@type': 'thumbnailFormatWebp'},
      'width': 128,
      'height': 128,
      'file': _file(stickerId + 1000),
    },
    'sticker': _file(stickerId),
  },
  'is_premium': false,
};

Map<String, dynamic> _textContent(String text) => {
  '@type': 'messageText',
  'text': {'@type': 'formattedText', 'text': text},
};

Map<String, dynamic> _reply(int messageId) => {
  '@type': 'messageReplyToMessage',
  'chat_id': _chatId,
  'message_id': messageId,
};

Map<String, dynamic> _message(
  int id, {
  required Map<String, dynamic> content,
  Map<String, dynamic>? replyTo,
}) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1700000000 + id,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 5},
  'content': content,
  'reply_to': replyTo ?? {'@type': 'messageReplyToMessage', 'chat_id': 0},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final scratch = Directory.systemTemp.createTempSync(
      'sticker_reply_pipeline',
    );
    _pngPath = '${scratch.path}/sticker.png';
    File(_pngPath).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      ),
    );
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getChat' => {
            '@type': 'chat',
            'id': _chatId,
            'title': 'Stickers',
            'type': {'@type': 'chatTypePrivate', 'user_id': 5},
            'permissions': {'can_send_basic_messages': true},
          },
          'getUser' => {
            '@type': 'user',
            'id': 5,
            'first_name': 'Ada',
            'type': {'@type': 'userTypeRegular'},
          },
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Me'},
          'getConnectionState' => {'@type': 'connectionStateReady'},
          // Newest first, the way TDLib answers getChatHistory.
          'getChatHistory' => {
            '@type': 'messages',
            'messages': [
              _message(12, content: _stickerContent(600), replyTo: _reply(13)),
              _message(13, content: _stickerContent(601)),
              _message(11, content: _stickerContent(500), replyTo: _reply(10)),
              _message(10, content: _textContent('the message being answered')),
            ],
          },
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });

  testWidgets('a sticker shows the quoted text it answers', (tester) async {
    await _pumpChat(tester);

    final quotes = find.byKey(const ValueKey('messageReplyQuote'));
    expect(quotes, findsNWidgets(2));
    // The text quote really names the answered message.
    expect(
      find.descendant(
        of: quotes.at(0),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('the message being answered'),
        ),
      ),
      findsOneWidget,
    );
    // Quoting a sticker names it too instead of leaving an empty panel.
    expect(
      find.descendant(
        of: quotes.at(1),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Sticker'),
        ),
      ),
      findsOneWidget,
      reason: 'a quoted sticker must not render a blank reply panel',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}

Future<void> _pumpChat(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'showChannelsTab': false,
    'showMomentsTab': false,
    'communitiesEnabled': false,
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
        ChangeNotifierProvider<AppLocaleController>.value(
          value: AppLocaleController(prefs),
        ),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
        ChangeNotifierProvider<TranslationController>.value(value: translation),
      ],
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.light,
          extensions: [AppColors.light],
          platform: TargetPlatform.iOS,
        ),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ChatView(chatId: _chatId, title: 'Stickers'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(seconds: 2));
}
