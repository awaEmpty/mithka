import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/archived_chats_view.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The archive row arrives on a transition, not on a cut: the slot's extent
/// grows first (the chats settle), then the row's content fades in and drops
/// into place while a warm halo blooms off the assistant avatar and dies out.
/// These pins hold the envelope; the exact numbers are free to be re-tuned,
/// the *shape* is not.

Map<String, dynamic> _chat(
  int id, {
  String list = 'chatListMain',
  int order = 100,
}) => {
  '@type': 'chat',
  'id': id,
  'title': 'Chat $id',
  'type': {'@type': 'chatTypePrivate', 'user_id': 1000 + id},
  'last_message': {
    '@type': 'message',
    'id': id * 10,
    'chat_id': id,
    'date': order,
    'is_outgoing': false,
    'content': {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': 'hi', 'entities': <Object>[]},
    },
  },
  'positions': [
    {
      '@type': 'chatPosition',
      'list': {'@type': list},
      'order': order,
      'is_pinned': false,
    },
  ],
};

final _shotKey = GlobalKey();

Future<Uint8List> _capture(WidgetTester tester) async {
  final boundary =
      _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    bytes = data!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

/// Mean `R - B` of a horizontal band of the archive row, read from a raw RGBA
/// capture (the boundary is captured at 1:1, so test coordinates map straight
/// onto pixels).
///
/// Warmth isolates the light: both palettes tint with the archive amber, while
/// the row's text is neutral, so glyphs do not move the number. Light theme
/// tints towards amber (R up, B down) and the dark theme adds amber, so the
/// measurement has the same sign on both.
double _bandWarmth(
  Uint8List bytes,
  int imageWidth,
  Rect row,
  double topFraction,
  double heightFraction,
) {
  final y0 = row.top + row.height * topFraction;
  final y1 = y0 + row.height * heightFraction;
  // The text column only: the avatar fills the row's full height on the left.
  final x0 = (row.left + 200).round();
  final x1 = (row.right - 20).round();
  var sum = 0.0;
  var count = 0;
  for (var y = y0.round(); y < y1.round(); y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * imageWidth + x) * 4;
      sum += bytes[i] - bytes[i + 2];
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}

Future<void> _pump(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'communitiesEnabled': false,
    'showChatListSearch': true,
    'archivedChatsDisplayMode': 'pullDown',
  });
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: [AppColors.light]),
          home: const Scaffold(body: ChatListView()),
        ),
      ),
    ),
  );

  updates.add({
    '@type': 'updateConnectionState',
    'state': {'@type': 'connectionStateReady'},
  });
  for (final chat in [
    _chat(1, order: 300),
    for (var i = 2; i <= 20; i++) _chat(i, order: 300 - i),
    _chat(101, list: 'chatListArchive', order: 50),
  ]) {
    updates.add({'@type': 'updateNewChat', 'chat': chat});
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
}

double _contentOpacity(WidgetTester tester) => tester
    .widget<Opacity>(find.byKey(const ValueKey('archive-reveal-content')))
    .opacity;

double _glowProgress(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(const ValueKey('archive-reveal-glow')),
  );
  return (paint.foregroundPainter! as ChatListArchiveRevealGlow).progress;
}

/// Pulls the archive out with a deliberate 8x50 px gesture and leaves the
/// finger down right after the latch frame.
Future<TestGesture> _revealArchive(WidgetTester tester) async {
  final rowTop = tester.getTopLeft(find.text('Chat 1')).dy;
  final gesture = await tester.startGesture(Offset(200, rowTop + 30));
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 0; i < 8; i++) {
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.moveBy(const Offset(0, 8));
  await tester.pump();
  return gesture;
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

void main() {
  final updates = StreamController<Map<String, dynamic>>.broadcast();
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
          'getConnectionState' => {'@type': 'connectionStateReady'},
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets(
    'the archive row fades in and its halo blooms then dies',
    (tester) async {
      await _pump(tester, updates);
      final gesture = await _revealArchive(tester);

      expect(
        find.byType(ChatListPullDownArchiveReveal),
        findsOneWidget,
        reason: 'the reveal transition must wrap the arriving row',
      );
      expect(
        _contentOpacity(tester),
        lessThan(0.05),
        reason:
            'the row arrives empty: its background is the list colour, so the '
            'first frame must not cut the content in',
      );

      await tester.pump(const Duration(milliseconds: 180));
      final midOpacity = _contentOpacity(tester);
      final midGlow = _glowProgress(tester);
      expect(
        midOpacity,
        allOf(greaterThan(0.0), lessThan(1.0)),
        reason: 'the content is mid-fade at 180ms',
      );
      expect(
        midGlow,
        greaterThan(0.0),
        reason: 'the halo is lit while the row fills its slot',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _contentOpacity(tester),
        1.0,
        reason: 'the row is fully in by the end of the transition',
      );
      expect(
        _glowProgress(tester),
        0.0,
        reason: 'the halo is a passing light, not a permanent state',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_contentOpacity(tester), 1.0);
      expect(_glowProgress(tester), 0.0);
      expect(find.byType(ArchivedChatsRow), findsOneWidget);

      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the arrival light falls from the top edge of the row',
    (tester) async {
      await _pump(tester, updates);
      final gesture = await _revealArchive(tester);
      // Peak of the light, row fully in.
      await tester.pump(const Duration(milliseconds: 180));

      final row = tester.getRect(find.byType(ArchivedChatsRow));
      final bytes = await _capture(tester);
      final width =
          tester.view.physicalSize.width ~/ tester.view.devicePixelRatio;
      // From 12% down: the row's first few pixels sit under the pinned search
      // row while the slot is still growing.
      final bands = [
        for (final fraction in [0.12, 0.35, 0.58, 0.8])
          _bandWarmth(bytes, width, row, fraction, 0.08),
      ];
      for (var i = 1; i < bands.length; i++) {
        expect(
          bands[i],
          lessThan(bands[i - 1] - 1),
          reason:
              'band $i (${bands.map((b) => b.toStringAsFixed(1)).toList()}) '
              'must be dimmer than the one above it: the light comes from the '
              'row\'s top edge, not from around the avatar or across the row',
        );
      }
      expect(
        bands.first - bands.last,
        greaterThan(10),
        reason:
            'the top of the row is clearly lit and its bottom is not — '
            'measured ${bands.first.toStringAsFixed(1)} vs '
            '${bands.last.toStringAsFixed(1)}',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reduced motion shows the row settled, with no fade or halo',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pump(tester, updates);

      final gesture = await _revealArchive(tester);
      expect(
        _contentOpacity(tester),
        1.0,
        reason: 'a reduced-motion session never sees a half-faded row',
      );
      expect(_glowProgress(tester), 0.0);

      await gesture.up();
      await tester.pumpAndSettle();
      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
