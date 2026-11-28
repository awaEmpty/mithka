//
//  rich_button_row_test.dart
//
//  Rich-message page buttons are part of the post body, not the reply markup.
//  exteraless lays a pageBlockButtonRow out as one line of pill buttons:
//  label width + 20pt padding each side, 7pt gaps, and FILL (the block's
//  flagless default) stretching the row across the post. The fork used a Wrap
//  of bordered chips, so three buttons broke into ragged rows.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _button(String label, {String? url}) => {
  'text': {'@type': 'richTextPlain', 'text': label},
  'type': {
    '@type': 'inlineKeyboardButtonTypeUrl',
    'url': url ?? 'https://example.com/$label',
  },
};

MessageButton _modelButton(String label) => MessageButton(
  text: label,
  type: 'inlineKeyboardButtonTypeUrl',
  url: 'https://example.com/$label',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
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

  Future<void> pumpRow(
    WidgetTester tester, {
    required List<String> labels,
    String alignment = 'fill',
    bool outgoing = false,
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    tester.view
      ..physicalSize = const Size(1260, 2700)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final message = ChatMessage(
      id: 900,
      isOutgoing: outgoing,
      text: '',
      date: 10,
      contentType: 'messageRichMessage',
      richBlocks: [
        RichMessageBlock.buttonRow([
          for (final label in labels) _modelButton(label),
        ], horizontalAlignment: alignment),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: message,
              peerTitle: 'TrollStore',
              isGroup: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  test('a page block without align parses as FILL', () {
    final blocks = TDParse.richMessageBlocks({
      '@type': 'messageRichMessage',
      'message': {
        'blocks': [
          {
            '@type': 'pageBlockButtonRow',
            'buttons': [_button('A'), _button('B'), _button('C')],
          },
        ],
      },
    });
    expect(blocks, hasLength(1));
    expect(blocks.single.kind, RichMessageBlockKind.buttonRow);
    expect(blocks.single.horizontalAlignment, 'fill');
    expect(blocks.single.buttons, hasLength(3));
  });

  test('an explicit page block alignment survives parsing', () {
    for (final (type, expected) in [
      ('pageBlockHorizontalAlignmentLeft', 'left'),
      ('pageBlockHorizontalAlignmentCenter', 'center'),
      ('pageBlockHorizontalAlignmentRight', 'right'),
    ]) {
      final blocks = TDParse.richMessageBlocks({
        '@type': 'messageRichMessage',
        'message': {
          'blocks': [
            {
              '@type': 'pageBlockButtonRow',
              'align': {'@type': type},
              'buttons': [_button('A')],
            },
          ],
        },
      });
      expect(blocks.single.horizontalAlignment, expected);
    }
  });

  testWidgets('three FILL buttons share one full-width row', (tester) async {
    await pumpRow(tester, labels: ['A', 'B', 'C']);

    final row = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-row')),
    );
    final a = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-A')),
    );
    final b = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-B')),
    );
    final c = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-C')),
    );

    // One line, exteraless's 18 + fontSize pill height.
    expect(a.top, closeTo(b.top, 0.01));
    expect(b.top, closeTo(c.top, 0.01));
    expect(a.height, closeTo(34, 0.01));
    expect(a.height, closeTo(b.height, 0.01));

    // FILL stretches the row exactly across the post's content width, with
    // two 7pt gaps and three equal shares (all labels are short).
    expect(a.width, closeTo(b.width, 0.5));
    expect(b.width, closeTo(c.width, 0.5));
    expect(a.width + b.width + c.width + 14, closeTo(row.width, 0.6));
    expect(row.width, greaterThan(250));

    // Pills, not rounded cards: the material's shape is a stadium.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('rich-message-button-A')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.shape, isA<StadiumBorder>());
  });

  testWidgets('a centered row keeps natural widths and centers itself', (
    tester,
  ) async {
    await pumpRow(tester, labels: ['Open', 'Later']);
    final filled = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-row')),
    );

    await pumpRow(tester, labels: ['Open', 'Later'], alignment: 'center');
    final centered = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-row')),
    );
    expect(centered.width, lessThan(filled.width));
    expect(centered.center.dx, closeTo(filled.center.dx, 0.6));
  });

  testWidgets('a long label squeezes the row instead of wrapping', (
    tester,
  ) async {
    await pumpRow(
      tester,
      labels: ['A very long button label that cannot fit', 'B', 'C'],
    );
    final row = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-row')),
    );
    final long = tester.getRect(
      find.byKey(
        const ValueKey(
          'rich-message-button-A very long button label that cannot fit',
        ),
      ),
    );
    final b = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-B')),
    );
    final c = tester.getRect(
      find.byKey(const ValueKey('rich-message-button-C')),
    );

    // exteraless keeps a button row on one line: the long pill takes the
    // space it needs, the short ones shrink, and the row still fits.
    expect(long.top, closeTo(b.top, 0.01));
    expect(b.top, closeTo(c.top, 0.01));
    expect(long.width, greaterThan(b.width));
    expect(long.width + b.width + c.width + 14, closeTo(row.width, 0.6));
    expect(row.width, greaterThan(250));
  });
}
