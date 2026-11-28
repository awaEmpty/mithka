//
//  A deleted message's kept copy renders its mirrored media instead of a kind
//  label (Telegram §1.4 self-build feature). Photos paint the snapshot file;
//  other kinds show a file row with the recorded name. The kind label stays
//  the fallback only when no snapshot exists.
//

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heroicons_flutter/heroicons_flutter.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/history/message_history_models.dart';
import 'package:mithka/history/message_media_snapshot_view.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = allowTelegramTosViolations;

/// A 1x1 transparent PNG: enough for Image.file to decode in a test.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

MessageHistoryEntry _entry({
  required String kindKey,
  required String mediaPath,
  String posterPath = '',
  String text = '',
  String fileName = '',
  int width = 1,
  int height = 1,
}) => MessageHistoryEntry(
  accountUserId: 7,
  chatId: 11,
  messageId: 100,
  senderId: 42,
  date: 1700000000,
  text: text,
  kindKey: kindKey,
  state: MessageHistoryState.deleted,
  deletedAt: 1700009999,
  events: const [],
  mediaPath: mediaPath,
  mediaPosterPath: posterPath,
  mediaWidth: width,
  mediaHeight: height,
  mediaFileName: fileName,
);

ChatMessage _ghost(MessageHistoryEntry entry, {String? text}) => ChatMessage(
  id: entry.messageId,
  isOutgoing: false,
  text: text ?? entry.text,
  date: entry.date,
  chatId: entry.chatId,
  senderId: entry.senderId,
  contentType: 'mithkaGhost',
)..mirrorEntry = entry;

Future<void> _pumpBubble(WidgetTester tester, ChatMessage message) async {
  SharedPreferences.setMockInitialValues(const {});
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              MessageBubble(
                message: message,
                peerTitle: 'Peer',
                isGroup: false,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // The snapshot widget resolves File.exists() asynchronously.
  await tester.pump();
  await tester.pump();
}

void main() {
  if (!_enabled) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mithka-kept-media');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  testWidgets('a deleted photo renders its snapshot, not the kind label', (
    tester,
  ) async {
    final file = File('${dir.path}/kept.png')..writeAsBytesSync(_pngBytes);
    final entry = _entry(kindKey: 'historyKindPhoto', mediaPath: file.path);
    await _pumpBubble(tester, _ghost(entry));

    expect(find.byType(MediaSnapshotView), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // The old placeholder text must be gone now that the media exists.
    expect(find.text('Photo', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a deleted document shows its recorded file name', (
    tester,
  ) async {
    final file = File('${dir.path}/kept.bin')..writeAsBytesSync(const [1, 2]);
    final entry = _entry(
      kindKey: 'historyKindDocument',
      mediaPath: file.path,
      fileName: 'report.pdf',
    );
    await _pumpBubble(tester, _ghost(entry));

    expect(find.text('report.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a deleted video previews its poster and keeps the play badge', (
    tester,
  ) async {
    final video = File('${dir.path}/kept.mp4')
      ..writeAsBytesSync(const [1, 2, 3]);
    final poster = File('${dir.path}/kept.jpg')..writeAsBytesSync(_pngBytes);
    final entry = _entry(
      kindKey: 'historyKindVideo',
      mediaPath: video.path,
      posterPath: poster.path,
      width: 640,
      height: 360,
      fileName: 'clip.mp4',
    );
    await _pumpBubble(tester, _ghost(entry));

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(HeroiconsOutline.play), findsOneWidget);
    expect(find.text('Video', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a deleted static sticker paints the sticker itself', (
    tester,
  ) async {
    final sticker = File('${dir.path}/kept.webp')..writeAsBytesSync(_pngBytes);
    final entry = _entry(
      kindKey: 'historyKindSticker',
      mediaPath: sticker.path,
      width: 512,
      height: 512,
    );
    await _pumpBubble(tester, _ghost(entry));

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Sticker', findRichText: true), findsNothing);
    // A sticker keeps the sticker shape: no media card around it, and the
    // original 512² box paints at the 120pt sticker side.
    expect(find.byType(MediaSnapshotView), findsNothing);
    expect(tester.getSize(find.byType(Image)), const Size(120, 120));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a ghost without a snapshot keeps the kind label', (
    tester,
  ) async {
    final entry = _entry(kindKey: 'historyKindPhoto', mediaPath: '');
    // The view model substitutes the localized kind label when a media ghost
    // has no snapshot (it is the ghost's whole body).
    await _pumpBubble(tester, _ghost(entry, text: 'Photo'));

    expect(find.byType(MediaSnapshotView), findsNothing);
    // The text bubble paints through RichText, so the finder must look there.
    expect(find.text('Photo', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
