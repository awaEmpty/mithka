//
//  mithkax_r20_composer_network_test.dart
//
//  Round-20 behaviours that are pure enough to pin without a device:
//  the composer's bot-command styling, the block-edge trim that removed the
//  blank strip under a quote or code plate, and the network monitor that makes
//  TDLib redial after a Wi-Fi/VPN change.
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart'
    show trimmedMessageBlockRange;
import 'package:mithka/chat/stickers/emoji_text_controller.dart';
import 'package:mithka/platform/network_change_monitor.dart';
import 'package:mithka/theme/app_theme.dart';

TextStyle? _styleOf(TextSpan root, String run) {
  TextStyle? found;
  root.visitChildren((span) {
    if (found != null || span is! TextSpan) return false;
    if (span.text == run) {
      found = span.style;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  group('composer bot command', () {
    testWidgets('a leading /command is painted as a command, not prose', (
      tester,
    ) async {
      final controller = EmojiTextEditingController();
      addTearDown(controller.dispose);
      controller.value = const TextEditingValue(
        text: '/start@mithka_bot hello',
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final span = controller.buildTextSpan(
        context: context,
        style: const TextStyle(fontSize: 15),
        withComposing: false,
      );
      final command = _styleOf(span, '/start@mithka_bot');
      final rest = _styleOf(span, ' hello');
      expect(command?.color, context.colors.linkBlue);
      expect(command?.fontWeight, FontWeight.w500);
      expect(rest?.color, isNot(context.colors.linkBlue));
      expect(rest?.fontWeight, isNot(FontWeight.w500));
    });

    testWidgets('a slash mid-message stays plain text', (tester) async {
      final controller = EmojiTextEditingController();
      addTearDown(controller.dispose);
      controller.value = const TextEditingValue(text: 'hi /start');
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final span = controller.buildTextSpan(
        context: context,
        style: const TextStyle(fontSize: 15),
        withComposing: false,
      );
      expect(span.toPlainText(), 'hi /start');
      var styled = 0;
      span.visitChildren((child) {
        if (child is TextSpan &&
            child.style?.color == context.colors.linkBlue) {
          styled++;
        }
        return true;
      });
      expect(styled, 0);
    });
  });

  group('block edge trim', () {
    test('a fenced block loses its framing line breaks', () {
      const text = '\nprint(1);\n';
      expect(trimmedMessageBlockRange(text, 0, text.length), (1, 10));
    });

    test('a quote with no edge newlines keeps every line', () {
      const text = 'first\nsecond';
      expect(trimmedMessageBlockRange(text, 0, text.length), (0, 12));
    });

    test('an all-newline block collapses instead of painting empty lines', () {
      const text = '\n\n';
      final (start, end) = trimmedMessageBlockRange(text, 0, 2);
      expect(end, start);
    });

    test('crlf frames are trimmed from both ends', () {
      const text = '\r\ncode\r\n';
      expect(trimmedMessageBlockRange(text, 0, text.length), (2, 6));
    });
  });

  group('network monitor', () {
    test('an interface change makes TDLib redial', () async {
      var signature = 'wlan0|192.168.1.5';
      var refreshes = 0;
      final monitor = NetworkChangeMonitor(
        readInterfaces: () async => signature,
        refreshNetwork: () => refreshes++,
        connectionState: () => 'connectionStateReady',
      );
      await monitor.poll();
      expect(refreshes, 0, reason: 'the first sample only records the state');
      await monitor.poll();
      expect(refreshes, 0, reason: 'an unchanged set re-dials nothing');
      signature = 'rmnet0|10.0.0.2';
      await monitor.poll();
      expect(refreshes, 1);
    });

    test(
      'a dialling connection is reset once it outstays the budget',
      () async {
        var now = DateTime(2026, 1, 1, 12);
        const signature = 'wlan0|192.168.1.5';
        var refreshes = 0;
        final monitor = NetworkChangeMonitor(
          readInterfaces: () async => signature,
          refreshNetwork: () => refreshes++,
          connectionState: () => 'connectionStateConnecting',
          clock: () => now,
        );
        await monitor.poll();
        expect(refreshes, 0);
        now = now.add(const Duration(seconds: 25));
        await monitor.poll();
        expect(refreshes, 1, reason: 'a stall with an address is redialled');
        // The re-dial budget also throttles the next one.
        now = now.add(const Duration(seconds: 5));
        await monitor.poll();
        expect(refreshes, 1);
      },
    );

    test('airplane mode is not treated as a stalled dial', () async {
      var signature = '';
      var refreshes = 0;
      var now = DateTime(2026, 1, 1, 12);
      final monitor = NetworkChangeMonitor(
        readInterfaces: () async => signature,
        refreshNetwork: () => refreshes++,
        connectionState: () => 'connectionStateWaitingForNetwork',
        clock: () => now,
      );
      await monitor.poll();
      now = now.add(const Duration(minutes: 2));
      await monitor.poll();
      expect(refreshes, 0, reason: 'nothing to dial to without an address');
      signature = 'wlan0|192.168.1.5';
      await monitor.poll();
      expect(refreshes, 1, reason: 'the address coming back is a change');
    });
  });
}
