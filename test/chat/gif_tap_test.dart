//
//  gif_tap_test.dart
//
//  A GIF is a looping picture, not a video: tapping it must open the image
//  viewer path (which loops it without video chrome), never the video player.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late Directory scratch;
  late String stillPath;

  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('gif_tap');
    stillPath = '${scratch.path}/still.png';
    File(stillPath).writeAsBytesSync(
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

  testWidgets('tapping a GIF asks for the animation viewer, not video', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    tester.view
      ..physicalSize = const Size(1260, 2700)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var animations = 0;
    var videos = 0;
    final message = ChatMessage(
      id: 77,
      isOutgoing: false,
      text: '',
      date: 10,
      contentType: 'messageAnimation',
      image: TdFileRef(id: 1, localPath: stillPath),
      video: TdFileRef(id: 2, localPath: '${scratch.path}/missing.mp4'),
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
              onOpenAnimation: (_) => animations++,
              onPlayVideo: (_) => videos++,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(
      find.byKey(const ValueKey('message-animation-77')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(animations, 1);
    expect(videos, 0);
  });
}
