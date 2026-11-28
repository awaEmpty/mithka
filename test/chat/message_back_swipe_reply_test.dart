//
//  message_back_swipe_reply_test.dart
//
//  A page back-swipe and a message's swipe-to-reply both read the same finger,
//  but the page gesture is a raw listener outside the arena. Swiping right to
//  peel the page and then reversing left used to drag the row into a reply as
//  well. Once the page claims the contact the row must stay put.
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_swipe_reply.dart';
import 'package:mithka/components/full_page_back_swipe.dart';

void main() {
  testWidgets('a reversed back swipe does not reply to the message', (
    tester,
  ) async {
    var replies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FullPageBackSwipe(
            enabled: true,
            onBack: () {},
            child: Align(
              alignment: Alignment.topCenter,
              child: MessageSwipeReplyRow(
                onReply: () => replies++,
                child: const SizedBox(width: 320, height: 120),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MessageSwipeReplyRow)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // Rightward: the page takes the contact.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(15, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Reverse far past the reply trigger.
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      replies,
      0,
      reason: 'the leftward half of the back swipe must not commit a reply',
    );
    expect(FullPageBackSwipeClaim.active, isFalse);
  });

  testWidgets('a plain left swipe still replies', (tester) async {
    var replies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FullPageBackSwipe(
            enabled: true,
            onBack: () {},
            child: Align(
              alignment: Alignment.topCenter,
              child: MessageSwipeReplyRow(
                onReply: () => replies++,
                child: const SizedBox(width: 320, height: 120),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MessageSwipeReplyRow)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(replies, 1);
    expect(FullPageBackSwipeClaim.active, isFalse);
  });

  testWidgets('a reply drag dragged back does not start the back swipe', (
    tester,
  ) async {
    var replies = 0;
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FullPageBackSwipe(
            enabled: true,
            onBack: () => backs++,
            child: Align(
              alignment: Alignment.topCenter,
              child: MessageSwipeReplyRow(
                onReply: () => replies++,
                child: const SizedBox(width: 320, height: 120),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MessageSwipeReplyRow)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // Left first: the row takes the contact as a reply drag.
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(MessageReplySwipeClaim.active, isTrue);
    // Then back to the right, far past the back gesture's commit distance.
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      FullPageBackSwipeClaim.active,
      isFalse,
      reason: 'the page must not arm while the row owns the contact',
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(backs, 0, reason: 'the reversed reply drag must not pop the chat');
    expect(replies, 0, reason: 'dragging back cancels the reply');
    expect(FullPageBackSwipeClaim.active, isFalse);
    expect(MessageReplySwipeClaim.active, isFalse);
  });
}
