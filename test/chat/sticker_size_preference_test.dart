//
//  sticker size preference: one value (exteraless's 4..20, default 14) drives
//  the sticker box in the transcript. The controller maps it to a relative
//  scale of 1.0 at the stock setting; changing it must resize a mounted
//  sticker bubble without remounting the message.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/settings/appearance/sticker_size_settings_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => L10nFixtures.load().install());

  test('the controller maps the exteraless size to a relative scale', () async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    expect(theme.stickerMediaSize, 14);
    expect(theme.stickerMediaScale, 1.0);
    theme.stickerMediaSize = 20;
    expect(theme.stickerMediaScale, closeTo(1.4, 0.001));
    theme.stickerMediaSize = 2;
    expect(theme.stickerMediaScale, closeTo(0.2, 0.001));
    theme.stickerMediaSize = 99;
    expect(theme.stickerMediaSize, 20);
    // A 5% step is exactly 0.75 of a size unit; the slider maps each notch
    // back through the same formula.
    theme.stickerMediaSize = 14 + 5 * 15 / 100;
    expect(theme.stickerMediaScale, closeTo(1.05, 0.001));
  });

  testWidgets('a mounted sticker resizes when the preference changes', (
    tester,
  ) async {
    final updates = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(updates.close);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async => <String, dynamic>{'@type': 'ok'},
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    final scratch = Directory.systemTemp.createTempSync('sticker_size');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final stickerPath = '${scratch.path}/sticker.png';
    File(stickerPath).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      ),
    );

    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    final message = ChatMessage(
      id: 9,
      isOutgoing: false,
      text: '',
      date: 10,
      contentType: 'messageSticker',
      stickerFileId: 5,
      image: TdFileRef(id: 5, localPath: stickerPath),
      imageWidth: 512,
      imageHeight: 512,
    );
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
    expect(tester.getSize(find.byType(TDImage).first), const Size(120, 120));

    theme.stickerMediaSize = 20;
    await tester.pump();
    final resized = tester.getSize(find.byType(TDImage).first);
    expect(resized.width, closeTo(168, 0.5));
    expect(resized.height, closeTo(168, 0.5));
  });

  testWidgets('the settings page drives the shared size', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: const MaterialApp(home: StickerSizeSettingsView()),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('sticker-size-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-size-percent')), findsOneWidget);

    theme.stickerMediaSize = 20;
    await tester.pump();
    expect(find.text('140%'), findsOneWidget);

    // Dragging moves in whole 5% notches (24 divisions over 20%..140%).
    theme.stickerMediaSize = 14;
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('sticker-size-slider')),
      const Offset(24, 0),
    );
    await tester.pumpAndSettle();
    final percent = (theme.stickerMediaScale * 100).round();
    expect(percent, isNot(100));
    expect(percent % 5, 0);
    expect(find.text('$percent%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sticker-size-reset')));
    await tester.pump();
    expect(theme.stickerMediaSize, 14);
    expect(find.text('100%'), findsOneWidget);
  });
}
