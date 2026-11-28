//
//  message_bubble_meta_test.dart
//
//  Every message carries its send time INSIDE its own bubble, in the
//  bottom-right corner the reference client draws it in
//  (`ChatMessageCell.drawTimeInternal`: right edge at `backgroundWidth − 9dp`,
//  top at `layoutHeight − 6.5dp − timeLayout.height`). The old floating label
//  below the bubble and the band's leading timestamp sat outside the surface;
//  this suite pins the new geometry so neither can come back.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/image_media_album_bubble.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
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
          _ => throw StateError('Unexpected TDLib request: $request'),
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  Future<void> pumpBubble(
    WidgetTester tester,
    ChatMessage message, {
    bool outgoing = true,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: MessageBubble(
                message: message,
                peerTitle: 'Channel',
                isGroup: false,
                meId: 1,
                forceShowTimestamp: true,
                showChannelPostStats: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  ChatMessage message({
    int id = 9,
    bool outgoing = true,
    int viewCount = 0,
    String text = 'A post',
  }) => ChatMessage(
    id: id,
    isOutgoing: outgoing,
    text: text,
    date: 1700000000,
    contentType: 'messageText',
    senderId: outgoing ? 1 : 2,
    senderName: outgoing ? null : 'Alice',
    viewCount: viewCount,
  );

  testWidgets('the send time sits inside the bubble, bottom-right', (
    tester,
  ) async {
    await pumpBubble(tester, message(viewCount: 42));
    final time = find.byKey(const ValueKey('messageTappedTimestamp'));
    final bubble = find.byKey(const ValueKey('messageTextBubble-9'));
    expect(time, findsOneWidget);
    expect(bubble, findsOneWidget);

    final timeRect = tester.getRect(time);
    final bubbleRect = tester.getRect(bubble);
    expect(
      bubbleRect.contains(timeRect.topLeft) &&
          bubbleRect.contains(timeRect.bottomRight),
      isTrue,
      reason: 'time $timeRect must live inside the bubble $bubbleRect',
    );
    // The corner insets are the reference client's: a handful of dp, never a
    // row's worth of distance.
    expect(bubbleRect.right - timeRect.right, lessThan(24));
    expect(bubbleRect.bottom - timeRect.bottom, lessThan(8));
  });

  testWidgets('a bubble without outside chips still owns its time', (
    tester,
  ) async {
    await pumpBubble(tester, message());
    expect(find.byKey(const ValueKey('messageViews-9')), findsNothing);
    final time = find.byKey(const ValueKey('messageTappedTimestamp'));
    final bubble = tester.getRect(
      find.byKey(const ValueKey('messageTextBubble-9')),
    );
    expect(time, findsOneWidget);
    final timeRect = tester.getRect(time);
    expect(
      bubble.contains(timeRect.topLeft) &&
          bubble.contains(timeRect.bottomRight),
      isTrue,
      reason: 'no band exists at all: the time is still inside the bubble',
    );
  });

  testWidgets('an incoming message puts its time in the same corner', (
    tester,
  ) async {
    await pumpBubble(tester, message(outgoing: false), outgoing: false);
    final timeRect = tester.getRect(
      find.byKey(const ValueKey('messageTappedTimestamp')),
    );
    final bubble = tester.getRect(
      find.byKey(const ValueKey('messageTextBubble-9')),
    );
    expect(bubble.contains(timeRect.topLeft), isTrue);
    expect(bubble.contains(timeRect.bottomRight), isTrue);
  });

  testWidgets('an album caption carries the time inside the card', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);
    final albumCaption = ChatMessage(
      id: 31,
      isOutgoing: true,
      text: 'Caption',
      date: 1700000000,
      contentType: 'messageDocument',
      senderId: 1,
      document: MessageDocument(
        fileName: 'a.pdf',
        size: 10,
        ext: 'pdf',
        file: TdFileRef(id: 1),
      ),
    );
    final albumSecond = ChatMessage(
      id: 32,
      isOutgoing: true,
      text: '',
      date: 1700000000,
      contentType: 'messageDocument',
      senderId: 1,
      document: MessageDocument(
        fileName: 'b.pdf',
        size: 10,
        ext: 'pdf',
        file: TdFileRef(id: 2),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ImageMediaAlbumBubble(
                messages: [albumCaption, albumSecond],
                peerTitle: 'Channel',
                isGroup: false,
                meId: 1,
                onOpenImage: (message) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final timeRect = tester.getRect(
      find.byKey(const ValueKey('messageTappedTimestamp')),
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('messageImageAlbumCard-31')),
    );
    expect(
      card.contains(timeRect.topLeft) && card.contains(timeRect.bottomRight),
      isTrue,
      reason: 'album time $timeRect must live inside the card $card',
    );
    expect(card.bottom - timeRect.bottom, lessThan(10));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
