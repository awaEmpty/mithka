import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scroll offset of the chat list's vertical scrollable.
double _chatListPixels(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    if (element.widget is! Scrollable) continue;
    final state = (element as StatefulElement).state;
    if (state is ScrollableState && state.position.axis == Axis.vertical) {
      return state.position.pixels;
    }
  }
  return double.nan;
}

/// Drags straight down from the first chat row while the list rests at the
/// top, and reports the scroll offset reached mid-drag.
Future<double> _pullDownFromTop(
  WidgetTester tester, {
  required double fingersDown,
}) async {
  final firstRow = tester.getTopLeft(find.text('Chat 1')).dy;
  final gesture = await tester.startGesture(Offset(200, firstRow + 40));
  await tester.pump(const Duration(milliseconds: 40));
  var remaining = fingersDown;
  while (remaining > 0) {
    final step = remaining > 40 ? 40.0 : remaining;
    await gesture.moveBy(Offset(0, step));
    await tester.pump(const Duration(milliseconds: 16));
    remaining -= step;
  }
  final pixels = _chatListPixels(tester);
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 16));
  return pixels;
}

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

Future<void> _pump(
  WidgetTester tester,
  StreamController<Map<String, dynamic>> updates, {
  required List<Map<String, dynamic>> chats,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'communitiesEnabled': false,
    'showChatListSearch': true,
  });
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: const Scaffold(body: ChatListView()),
      ),
    ),
  );

  updates.add({
    '@type': 'updateConnectionState',
    'state': {'@type': 'connectionStateReady'},
  });
  updates.add({
    '@type': 'updateChatFolders',
    'chat_folders': <Map<String, dynamic>>[],
  });
  for (final chat in chats) {
    updates.add({'@type': 'updateNewChat', 'chat': chat});
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

/// Fixed metrics for one top-edge pull frame.
ScrollMetrics _pullMetrics(double pixels) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 5000,
  pixels: pixels,
  viewportDimension: 844,
  axisDirection: AxisDirection.down,
  devicePixelRatio: 3,
);

/// A pull must travel much farther than the row it reveals: the reference
/// client multiplies the finger delta by `startPullParallax − endPullParallax ·
/// k` (0.45 at rest, 0.20 once the row is fully out), and that damping is what
/// makes the gesture stop feeling like a hair trigger.
void _archivePullParallaxTests() {
  const rowHeight = 72.0;
  const physics = ChatListArchivePullPhysics(rowHeight: rowHeight);

  // A finger delta of +40 is the *pull*: the position subtracts the value
  // this returns from `pixels`, so a damped positive result is what makes the
  // list move less than the finger.
  test('top-edge pull is damped to the reference parallax', () {
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(0), 40),
      moreOrLessEquals(40 * kArchivePullStartParallax),
      reason: 'a pull that starts at rest moves 45% of the finger travel',
    );
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(-rowHeight / 2), 40),
      moreOrLessEquals(
        40 * (kArchivePullStartParallax - kArchivePullEndParallax * 0.5),
      ),
      reason: 'damping grows as half the row is out',
    );
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(-rowHeight), 40),
      moreOrLessEquals(40 * 0.2),
      reason: 'a fully revealed row damps the pull down to 20%',
    );
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(-rowHeight * 3), 40),
      moreOrLessEquals(40 * 0.2),
      reason: 'beyond a row the parallax keeps its floor instead of vanishing',
    );
  });

  test('only the pull at the top edge is damped', () {
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(120), 40),
      moreOrLessEquals(40),
      reason: 'a pull inside the content is plain scrolling',
    );
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(0), -40),
      moreOrLessEquals(-40),
      reason: 'an upward drag from the top is untouched by the parallax',
    );
    expect(
      physics.applyPhysicsToUserOffset(_pullMetrics(120), -40),
      moreOrLessEquals(-40),
      reason: 'scrolling forward is never damped',
    );
  });

  test('archive reveal waits for the reference snap height', () {
    expect(
      chatListShouldRevealPullDownArchive(pullOffset: 40, rowHeight: 72),
      isFalse,
      reason: '55% of a row is the old hair-trigger threshold',
    );
    expect(
      chatListShouldRevealPullDownArchive(pullOffset: 60, rowHeight: 72),
      isFalse,
      reason: '83% of a row is still short of SNAP_HEIGHT',
    );
    expect(
      chatListShouldRevealPullDownArchive(pullOffset: 62, rowHeight: 72),
      isTrue,
      reason: '86% of a row crosses the reference snap height',
    );
    expect(
      chatListShouldRevealPullDownArchive(pullOffset: 0, rowHeight: 0),
      isFalse,
      reason: 'an unmeasured row height never arms the reveal',
    );
  });
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

  group('archive pull physics', _archivePullParallaxTests);

  testWidgets(
    'no archive: top pull does not rubber-band the chat list',
    (tester) async {
      await _pump(
        tester,
        updates,
        chats: [_chat(1, order: 300), _chat(2, order: 200), _chat(3)],
      );
      final pixels = await _pullDownFromTop(tester, fingersDown: 200);
      expect(
        pixels,
        0.0,
        reason:
            'without a pull-down archive the top edge follows the platform '
            'default — no long elastic drag with nothing to reveal',
      );
      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'with archive: top pull keeps revealing the archive slot',
    (tester) async {
      await _pump(
        tester,
        updates,
        chats: [
          _chat(1, order: 300),
          _chat(2, order: 200),
          _chat(3),
          _chat(101, list: 'chatListArchive', order: 50),
        ],
      );
      expect(
        find.byType(ChatListPullDownArchiveSlot),
        findsOneWidget,
        reason: 'fixture must mount the pull-down archive slot',
      );
      final pixels = await _pullDownFromTop(tester, fingersDown: 200);
      expect(
        pixels,
        lessThan(0),
        reason: 'the archive reveal keeps its elastic negative offset',
      );
      await _dispose(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
