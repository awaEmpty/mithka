//
//  message_link_long_press_test.dart
//
//  exteraless opens a link's own menu when the long press lands on a link
//  (`ChatMessageCell.onLongPress` → `didLongPressLink`) and the message menu
//  everywhere else. These pin both halves plus the copy route and the message
//  typography ladder the same round aligned.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late String? clipboard;
  late bool longPressed;

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
          _ => throw StateError('Unexpected TDLib request: $request'),
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    clipboard = null;
    longPressed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpBubble(
    WidgetTester tester,
    String text, {
    List<MessageTextEntity> entities = const [],
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);
    final message = ChatMessage(
      id: 7,
      isOutgoing: false,
      text: text,
      date: 1,
      textEntities: entities,
      contentType: 'messageText',
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: MessageBubble(
                message: message,
                peerTitle: 'Chat',
                isGroup: false,
                onLongPress: (_, _, _) => longPressed = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Global point over character [index] of the paragraph that paints text
  /// containing [paragraphContaining].
  Offset pointOver(
    WidgetTester tester,
    int index, {
    required String paragraphContaining,
  }) {
    final widget = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere(
          (rich) => rich.text.toPlainText().contains(paragraphContaining),
        );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byWidget(widget),
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + 1),
    );
    final box = boxes.first;
    return paragraph.localToGlobal(
      Offset(box.left + 1, (box.top + box.bottom) / 2),
    );
  }

  testWidgets('a long press on a link opens the link menu only', (
    tester,
  ) async {
    const text = 'visit https://example.com/page now';
    await pumpBubble(tester, text);
    await tester.longPressAt(
      pointOver(
        tester,
        text.indexOf('example'),
        paragraphContaining: 'example.com',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('message-link-menu')), findsOneWidget);
    expect(longPressed, isFalse);
    // A URL offers 打开 / 复制 / 二维码, exteraless's order.
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Share QR code'), findsOneWidget);
  });

  testWidgets('copying a link writes its URL, not the visible label', (
    tester,
  ) async {
    const text = 'see https://example.com/page here';
    await pumpBubble(tester, text);
    await tester.longPressAt(
      pointOver(
        tester,
        text.indexOf('example'),
        paragraphContaining: 'example.com',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('message-link-action-copy')));
    await tester.pumpAndSettle();
    expect(clipboard, 'https://example.com/page');
    expect(find.byKey(const ValueKey('message-link-menu')), findsNothing);
    // Let the copy toast's own timer retire before the tree goes away.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a press off every link keeps the message menu', (tester) async {
    const text = 'visit https://example.com/page now';
    await pumpBubble(tester, text);
    await tester.longPressAt(
      pointOver(tester, text.indexOf('now'), paragraphContaining: 'visit'),
    );
    await tester.pumpAndSettle();
    expect(longPressed, isTrue);
    expect(find.byKey(const ValueKey('message-link-menu')), findsNothing);
  });

  test('message typography follows the exteraless ladder', () {
    // Theme.createCommonMessageResources() at SharedConfig.fontSize = 16.
    expect(AppTextSize.messageBody(TargetPlatform.android), 16);
    expect(AppTextSize.chatSecondary(16), 14);
    expect(AppTextSize.chatTime, 12);
    // chat_msgTextCode{,2,3}Paint: >220 / >80 / rest.
    expect(AppTextSize.messageCode(16, 40), 14);
    expect(AppTextSize.messageCode(16, 120), 13);
    expect(AppTextSize.messageCode(16, 400), 11);
    // layoutCode's language label: fontSize - 1 - decrement / 2.
    expect(AppTextSize.messageCodeLanguage(16, 40), 14);
    expect(AppTextSize.messageCodeLanguage(16, 300), 13);
    // Inline code is the body minus its own decrement.
    expect(AppTextSize.messageInlineCode(16, 8), 14);
    expect(
      AppTextStyle.messageBody(
        const Color(0xFF000000),
        platform: TargetPlatform.android,
      ).height,
      20 / 16,
    );
    expect(messageTextBubblePadding.horizontal, 22);
    expect(messageTextBubblePadding.vertical, 16);
  });

  testWidgets('the pressed link carries a select tint while its menu is open', (
    tester,
  ) async {
    const text = 'visit https://example.com/page now';
    await pumpBubble(tester, text);

    TextSpan linkSpan() {
      final widget = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere(
            (rich) => rich.text.toPlainText().contains('example.com'),
          );
      late TextSpan found;
      widget.text.visitChildren((span) {
        if (span is TextSpan && (span.text ?? '').contains('example.com')) {
          found = span;
          return false;
        }
        return true;
      });
      return found;
    }

    expect(linkSpan().style?.backgroundColor, isNull);

    await tester.longPressAt(
      pointOver(
        tester,
        text.indexOf('example'),
        paragraphContaining: 'example.com',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-link-menu')), findsOneWidget);
    expect(
      linkSpan().style?.backgroundColor,
      isNotNull,
      reason:
          'the link the menu belongs to must read as selected, the way '
          'exteraless paints chat_linkSelectBackground',
    );

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(linkSpan().style?.backgroundColor, isNull);
  });

  testWidgets('a fence\'s edge newlines add no blank strip to a code block', (
    tester,
  ) async {
    const framed = '\ncode line\n';
    await pumpBubble(
      tester,
      framed,
      entities: const [
        MessageTextEntity(
          offset: 0,
          length: framed.length,
          type: 'textEntityTypePreCode',
          language: 'dart',
        ),
      ],
    );
    final framedHeight = tester
        .getSize(find.byKey(const ValueKey('message-code-block-7-1-10')))
        .height;

    const bare = 'code line';
    await pumpBubble(
      tester,
      bare,
      entities: const [
        MessageTextEntity(
          offset: 0,
          length: bare.length,
          type: 'textEntityTypePreCode',
          language: 'dart',
        ),
      ],
    );
    final bareHeight = tester
        .getSize(find.byKey(const ValueKey('message-code-block-7-0-9')))
        .height;

    // Two unfiltered newlines would paint two extra empty code lines.
    expect(framedHeight, closeTo(bareHeight, 0.5));
  });
}
