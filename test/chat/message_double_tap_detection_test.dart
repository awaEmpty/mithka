//
//  message_double_tap_detection_test.dart
//
//  The bubble detects a double tap itself (a GestureDetector.onDoubleTap
//  starves every nested tap target), so the window and slop rules live in a
//  pure function that this file pins down.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';

void main() {
  const firstUp = Duration(milliseconds: 100);

  test('a second press inside the window and slop is a double tap', () {
    expect(
      isMessageDoubleTap(
        firstUp: firstUp,
        secondDown: const Duration(milliseconds: 250),
        travel: 2,
      ),
      isTrue,
    );
  });

  test('a second press after the double-tap window is another tap', () {
    expect(
      isMessageDoubleTap(
        firstUp: firstUp,
        secondDown: const Duration(milliseconds: 450),
        travel: 0,
      ),
      isFalse,
    );
  });

  test('a second press far from the first one is another tap', () {
    expect(
      isMessageDoubleTap(
        firstUp: firstUp,
        secondDown: const Duration(milliseconds: 200),
        travel: 40,
      ),
      isFalse,
    );
  });

  test('a second press before the first one releases is not a pair', () {
    expect(
      isMessageDoubleTap(
        firstUp: firstUp,
        secondDown: const Duration(milliseconds: 50),
        travel: 0,
      ),
      isFalse,
    );
  });
}
