//
//  sticker_reply_quote_test.dart
//
//  A sticker that answers another message must show WHICH message it answers.
//  exteraless draws the reply panel above the sticker's empty bubble; the
//  fork used to skip the quote for every background-less sticker, so the
//  reply was invisible. The quote keeps a readable floor width instead of
//  shrinking to the sticker's 120pt side.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late Directory scratch;
  late String stickerPath;

  setUpAll(() {
    // A real local file keeps TDImage's resolver synchronous: a bare file id
    // parks a three-minute download waiter that flutter_test reports as a
    // pending timer.
    scratch = Directory.systemTemp.createTempSync('sticker_reply_quote');
    stickerPath = '${scratch.path}/sticker.png';
    File(stickerPath).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      ),
    );
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async => <String, dynamic>{'@type': 'ok'},
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() {
    updates.close();
    scratch.deleteSync(recursive: true);
  });

  Future<void> pumpSticker(
    WidgetTester tester, {
    required bool withReply,
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    tester.view
      ..physicalSize = const Size(1260, 2736)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final message =
        ChatMessage(
            id: 77,
            isOutgoing: false,
            text: '',
            date: 10,
            contentType: 'messageSticker',
            stickerFileId: 500,
            image: TdFileRef(id: 500, localPath: stickerPath),
            replyToMessageId: withReply ? 12 : null,
            replyToDate: withReply ? 9 : null,
          )
          ..replyToSender = withReply ? 'Ada' : null
          ..replyToPreview = withReply ? 'the message being answered' : null;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: message,
              peerTitle: 'Ada',
              isGroup: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a replying sticker shows the reply quote above it', (
    tester,
  ) async {
    await pumpSticker(tester, withReply: true);

    final quote = find.byKey(const ValueKey('messageReplyQuote'));
    expect(quote, findsOneWidget);
    // The quoted message's text is really rendered inside the panel.
    expect(
      find.descendant(
        of: quote,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('the message being answered'),
        ),
      ),
      findsOneWidget,
    );

    // The quote hangs above the sticker, not beside or below it.
    final quoteRect = tester.getRect(quote);
    final stickerRect = tester.getRect(find.byType(TDImage).first);
    expect(quoteRect.bottom, lessThanOrEqualTo(stickerRect.top));

    // A 120pt sticker would make a 120pt quote unreadable; the marker keeps a
    // readable floor while never growing past the bubble lane. It is a thin
    // rule + author/preview, not the filled reply card.
    expect(quoteRect.width, greaterThanOrEqualTo(148));
    expect(
      find.byKey(const ValueKey('messageReplyStickerAuthor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('messageReplyNavigateUpIcon')),
      findsNothing,
    );
  });

  testWidgets('a sticker without a reply reserves no quote', (tester) async {
    await pumpSticker(tester, withReply: false);
    expect(find.byKey(const ValueKey('messageReplyQuote')), findsNothing);
  });
}
