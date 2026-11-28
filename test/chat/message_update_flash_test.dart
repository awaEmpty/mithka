//
//  message_update_flash_test.dart
//
//  Other clients blink an updated message: when a bot (or another device)
//  rewrites a message in place, the body fades back in once so the reader
//  notices the text changed under their eyes. The flash must belong to a
//  real body change — repaints, reactions and view counts stay still.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/settings/privacy_security/keyword_blocker.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = 42;

Map<String, dynamic> _textContent(String text) => {
  '@type': 'messageText',
  'text': {'@type': 'formattedText', 'text': text, 'entities': []},
};

ChatViewModel _model() {
  final model = ChatViewModel(
    chatId: _chatId,
    title: 'Bot',
    markReadOnOpen: false,
    sessionMessages: [
      ChatMessage(
        id: 1,
        chatId: _chatId,
        isOutgoing: false,
        text: 'first answer',
        date: 1,
      ),
    ],
  );
  model.primeMessageIndexesForTesting();
  return model;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    KeywordBlocker.shared.initialize(await SharedPreferences.getInstance());
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

  tearDownAll(() => updates.close());

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    KeywordBlocker.shared.replaceAll(const []);
  });

  test('a content update that changes the text bumps the flash token', () {
    final model = _model();
    addTearDown(model.dispose);
    final message = model.messages.single;
    expect(message.contentFlashToken, 0);

    model.applyLiveUpdateForTesting({
      '@type': 'updateMessageContent',
      'chat_id': _chatId,
      'message_id': 1,
      'new_content': _textContent('second answer'),
    });

    expect(message.text, 'second answer');
    expect(message.contentFlashToken, 1);
    expect(message.contentFlashAtMillis, greaterThan(0));
  });

  test('a pending send never blinks while its body settles', () {
    final model = ChatViewModel(
      chatId: _chatId,
      title: 'Bot',
      markReadOnOpen: false,
      sessionMessages: [
        ChatMessage(
          id: 2,
          chatId: _chatId,
          isOutgoing: true,
          text: '',
          date: 2,
          isSending: true,
        ),
      ],
    );
    addTearDown(model.dispose);
    model.primeMessageIndexesForTesting();
    final message = model.messages.single;

    model.applyLiveUpdateForTesting({
      '@type': 'updateMessageContent',
      'chat_id': _chatId,
      'message_id': 2,
      'new_content': _textContent('caption arriving'),
    });

    expect(message.text, 'caption arriving');
    expect(message.contentFlashToken, 0);
  });

  test('an identical content repaint does not bump the token', () {
    final model = _model();
    addTearDown(model.dispose);
    final message = model.messages.single;

    // A media refresh / local echo can repeat the body it already has.
    model.applyLiveUpdateForTesting({
      '@type': 'updateMessageContent',
      'chat_id': _chatId,
      'message_id': 1,
      'new_content': _textContent('first answer'),
    });

    expect(message.contentFlashToken, 0);
  });

  testWidgets('the bubble blinks once when the token moves', (tester) async {
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    final message = ChatMessage(
      id: 7,
      isOutgoing: false,
      text: 'first answer',
      date: 1,
    );
    late StateSetter rebuild;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return MessageBubble(
                  message: message,
                  peerTitle: 'Bot',
                  isGroup: false,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    FadeTransition flash() => tester.widget<FadeTransition>(
      find.byKey(const ValueKey('messageUpdateFlash-7')),
    );

    expect(flash().opacity.value, 1);

    // An unrelated rebuild never dims the bubble.
    rebuild(() {});
    await tester.pump();
    expect(flash().opacity.value, 1);

    // The bot rewrites the message: the body fades back in.
    message.text = 'second answer';
    message.contentFlashToken++;
    message.contentFlashAtMillis = DateTime.now().millisecondsSinceEpoch;
    rebuild(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(flash().opacity.value, lessThan(1));

    await tester.pump(const Duration(milliseconds: 400));
    expect(flash().opacity.value, 1);

    // An edit the reader scrolled past never blinks when the bubble finally
    // mounts: the token moves but the moment is stale.
    message.text = 'third answer';
    message.contentFlashToken++;
    message.contentFlashAtMillis = DateTime.now().millisecondsSinceEpoch - 5000;
    rebuild(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(flash().opacity.value, 1);
  });
}
