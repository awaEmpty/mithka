//
//  reply_sender_style_test.dart
//
//  exteraless paints a reply line in the QUOTED author's peer colour and
//  watermarks their custom emoji status in it. The appearance switch can turn
//  that off and leave a plain theme-coloured marker.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/message_name_colors.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async => switch (request['@type']) {
          'getCustomEmojiStickers' => <String, dynamic>{
            '@type': 'stickers',
            'stickers': const <Map<String, dynamic>>[],
          },
          _ => <String, dynamic>{'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  Future<ThemeController> pumpReply(
    WidgetTester tester, {
    required ChatMessage message,
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    tester.view
      ..physicalSize = const Size(1260, 2700)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: message,
              peerTitle: 'Discussion',
              isGroup: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return theme;
  }

  ChatMessage replyMessage() =>
      ChatMessage(
          id: 5,
          isOutgoing: false,
          text: '谢谢',
          date: 10,
          contentType: 'messageText',
          replyToMessageId: 1,
          replyToDate: 8,
          replyToSenderAccentColorId: 2,
          replyToSenderEmojiStatusId: 600,
          replyToSenderIsPremium: true,
        )
        ..replyToSender = 'Ada'
        ..replyToPreview = 'the quoted line';

  BoxDecoration quoteDecoration(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.byKey(const ValueKey('messageReplyQuote')),
              )
              .decoration!
          as BoxDecoration;

  testWidgets('the marker takes the quoted author colour and emoji', (
    tester,
  ) async {
    final message = replyMessage();
    await pumpReply(tester, message: message);

    final senderColor = messageNameColorForSender(
      theme: null,
      accentColorId: message.replyToSenderAccentColorId,
      showNameColors: true,
      nameColorsDisabledFallback: Colors.black,
    );
    expect(quoteDecoration(tester).color, senderColor.withValues(alpha: 0.10));
    expect(
      find.byKey(const ValueKey('messageReplySenderEmojiStatus')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('messageReplyNavigateUpIcon')),
      findsNothing,
    );
    final previews = tester.widgetList<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('messageReplyQuote')),
        matching: find.byType(RichText),
      ),
    );
    expect(
      previews.any(
        (text) =>
            text.maxLines == 1 &&
            text.text.style?.fontSize == AppTextSize.messageBody(),
      ),
      isTrue,
    );
  });

  testWidgets('turning the switch off leaves a plain theme colour', (
    tester,
  ) async {
    final theme = await pumpReply(tester, message: replyMessage());
    final styled = quoteDecoration(tester).color;

    theme.replyQuoteSenderStyle = false;
    await tester.pump();

    expect(quoteDecoration(tester).color, isNot(styled));
    expect(
      quoteDecoration(tester).color,
      AppTheme.brand.withValues(alpha: 0.10),
    );
    expect(
      find.byKey(const ValueKey('messageReplySenderEmojiStatus')),
      findsNothing,
    );
  });
}
