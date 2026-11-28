//
//  message_arrival_test.dart
//
//  A message that lands in an open transcript plays a short entrance — an
//  incoming one and an own send alike; a row that was already on screen
//  (initial page, history page-in, scroll rebind) must never replay it. These
//  pin both halves plus the resting fast path, and the hand-over from a
//  pending send's local echo to its server id.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chat/messages/message_arrival.dart';
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Each chat-level test opens its own chat id: the transcript keeps a static
// session cache and scroll snapshot per chat, and a re-used id would restore
// the previous test's transcript (or its discarded pending ids) into the next.
var _chatId = 880;
const _peerUserId = 881;

// Server ids are `server_id << 20`; a pending send's local echo counts from a
// separate small counter, which is why the fixture keeps the two ranges apart.
const _firstServerId = 1048576;
const _secondServerId = 2097152;
const _sentServerId = 3145728;

Map<String, dynamic> _message(
  int id,
  String text, {
  bool outgoing = false,
  bool pending = false,
}) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1700000000 + id,
  'is_outgoing': outgoing,
  if (pending) 'sending_state': {'@type': 'messageSendingStatePending'},
  'sender_id': {
    '@type': 'messageSenderUser',
    'user_id': outgoing ? 1 : _peerUserId,
  },
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text},
  },
};

List<Map<String, dynamic>> _history() => [
  _message(_firstServerId, 'History hello'),
  _message(_secondServerId, 'History again'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessageArrival widget', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool animate,
      bool outgoing = false,
      Duration? startedAt,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageArrival(
              animate: animate,
              outgoing: outgoing,
              startedAt: startedAt,
              child: const SizedBox(width: 120, height: 40, child: Text('hi')),
            ),
          ),
        ),
      );
    }

    Opacity? opacityOf(WidgetTester tester) {
      final finder = find.descendant(
        of: find.byType(MessageArrival),
        matching: find.byType(Opacity),
      );
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<Opacity>(finder.first);
    }

    testWidgets('a live arrival fades and rises into place', (tester) async {
      await pump(tester, animate: true);
      expect(opacityOf(tester)?.opacity, 0);
      final rises = tester
          .widgetList<Transform>(
            find.descendant(
              of: find.byType(MessageArrival),
              matching: find.byType(Transform),
            ),
          )
          .map((transform) => transform.transform.getTranslation().y);
      expect(rises.any((dy) => dy > 0), isTrue);

      await tester.pump(const Duration(milliseconds: 120));
      final mid = opacityOf(tester)?.opacity ?? 1;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));

      await tester.pump(const Duration(milliseconds: 300));
      expect(opacityOf(tester), isNull);
      expect(
        tester.getRect(find.byType(MessageArrival)),
        tester.getRect(find.text('hi')),
      );
    });

    testWidgets('an existing row paints at rest with no wrapper', (
      tester,
    ) async {
      await pump(tester, animate: false);
      expect(opacityOf(tester), isNull);
    });

    testWidgets('a row taking over an entrance in flight resumes it', (
      tester,
    ) async {
      // An own send swaps the row onto its server id mid-entrance; the rebuilt
      // row must continue at the share already played, not restart from 0.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      await pump(
        tester,
        animate: true,
        outgoing: true,
        startedAt: Duration.zero,
      );
      final resumed = opacityOf(tester)?.opacity;
      expect(resumed, isNotNull);
      expect(resumed, greaterThan(0.3));
      expect(resumed, lessThan(1));
    });

    test('progressAt reads the share of the entrance already played', () {
      const start = Duration(seconds: 12);
      MessageArrival at() => const MessageArrival(
        animate: true,
        outgoing: true,
        startedAt: start,
        child: SizedBox(),
      );
      final half = Duration(
        milliseconds: MessageArrival.duration.inMilliseconds ~/ 2,
      );
      expect(at().progressAt(start), 0);
      expect(at().progressAt(start + half), closeTo(0.5, 0.001));
      expect(at().progressAt(start + const Duration(seconds: 1)), 1);
      expect(at().progressAt(start - const Duration(seconds: 1)), 0);
      expect(
        const MessageArrival(
          animate: true,
          outgoing: true,
          child: SizedBox(),
        ).progressAt(start),
        0,
        reason: 'no moment recorded means a fresh arrival',
      );
    });

    testWidgets('a row whose entrance is already over opens at rest', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await pump(tester, animate: true, startedAt: Duration.zero);
      expect(opacityOf(tester), isNull);
    });
  });

  group('new message in an open transcript', () {
    late StreamController<Map<String, dynamic>> updates;

    setUpAll(() {
      updates = StreamController<Map<String, dynamic>>.broadcast();
      TdClient.shared.configureProxy(
        TdClientProxyTransport(
          accountSlot: 0,
          query: (request) async => switch (request['@type']) {
            'getChat' => {
              '@type': 'chat',
              'id': _chatId,
              'title': 'Arrival chat',
              'type': {'@type': 'chatTypePrivate', 'user_id': _peerUserId},
              'permissions': {
                '@type': 'chatPermissions',
                'can_send_basic_messages': true,
              },
              'last_message': _history().last,
            },
            'getUser' => {
              '@type': 'user',
              'id': _peerUserId,
              'first_name': 'Peer',
              'last_name': '',
              'type': {'@type': 'userTypeRegular'},
            },
            'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Me'},
            'getConnectionState' => {'@type': 'connectionStateReady'},
            'getChatHistory' => {
              '@type': 'messages',
              'messages': _history().reversed.toList(),
            },
            'getMessage' => _message(request['message_id'] as int, 'Fetched'),
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

    Future<void> pumpChat(WidgetTester tester, int chatId) async {
      _chatId = chatId;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({
        'showChannelsTab': false,
        'showMomentsTab': false,
        'communitiesEnabled': false,
      });
      final prefs = await SharedPreferences.getInstance();
      final theme = ThemeController(prefs);
      final accounts = AccountStore(prefs);
      final auth = AuthManager();
      final translation = TranslationController(prefs);
      addTearDown(theme.dispose);
      addTearDown(accounts.dispose);
      addTearDown(auth.dispose);
      addTearDown(translation.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeController>.value(value: theme),
            ChangeNotifierProvider<AppLocaleController>.value(
              value: AppLocaleController(prefs),
            ),
            ChangeNotifierProvider<AccountStore>.value(value: accounts),
            ChangeNotifierProvider<AuthManager>.value(value: auth),
            ChangeNotifierProvider<TranslationController>.value(
              value: translation,
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(
              brightness: Brightness.light,
              extensions: [AppColors.light],
              platform: TargetPlatform.iOS,
            ),
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatView(chatId: _chatId, title: 'Arrival chat'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // The opening sequence positions the viewport across several frames;
      // a live arrival only animates once that has settled.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    MessageArrival arrivalOf(WidgetTester tester, String text) {
      final row = find.ancestor(
        of: find.text(text, findRichText: true),
        matching: find.byType(MessageArrival),
      );
      expect(row, findsOneWidget, reason: 'row for "$text" is on screen');
      return tester.widget<MessageArrival>(row);
    }

    Opacity? entranceOf(WidgetTester tester, String text) {
      final finder = find.descendant(
        of: find.ancestor(
          of: find.text(text, findRichText: true),
          matching: find.byType(MessageArrival),
        ),
        matching: find.byType(Opacity),
      );
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<Opacity>(finder.first);
    }

    testWidgets('the initial page opens at rest', (tester) async {
      await pumpChat(tester, 880);
      expect(arrivalOf(tester, 'History hello').animate, isFalse);
      expect(arrivalOf(tester, 'History again').animate, isFalse);
    });

    testWidgets('a live arrival plays the entrance exactly once', (
      tester,
    ) async {
      await pumpChat(tester, 881);
      updates.add({
        '@type': 'updateNewMessage',
        'message': _message(4194304, 'Live hello'),
      });
      await tester.pump();
      await tester.pump();

      // The row's prop may already have been rebuilt back to false (sender
      // resolution re-syncs the transcript); what matters is that its State
      // is still rising, not that the last widget instance says "arrive".
      arrivalOf(tester, 'Live hello');
      final opacity = entranceOf(tester, 'Live hello');
      expect(opacity, isNotNull);
      expect(opacity!.opacity, lessThan(1));

      // Settled: the wrappers are gone and the row paints at rest.
      await tester.pump(const Duration(milliseconds: 400));
      expect(entranceOf(tester, 'Live hello'), isNull);

      // A later rebuild of the same row must not restart it.
      updates.add({
        '@type': 'updateMessageContent',
        'chat_id': _chatId,
        'message_id': 4194304,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'Live hello edited'},
        },
      });
      await tester.pump();
      await tester.pump();
      expect(
        entranceOf(tester, 'Live hello edited'),
        isNull,
        reason: 'an edit re-sync is not an arrival',
      );
    });

    testWidgets('an own send rises in like an incoming message', (
      tester,
    ) async {
      await pumpChat(tester, 882);
      updates.add({
        '@type': 'updateNewMessage',
        // The local echo's temporary id sits far BELOW the newest server id;
        // it is still the newest thing on screen.
        'message': _message(1, 'Own hello', outgoing: true, pending: true),
      });
      await tester.pump();
      await tester.pump();

      expect(arrivalOf(tester, 'Own hello').outgoing, isTrue);
      final opacity = entranceOf(tester, 'Own hello');
      expect(opacity, isNotNull, reason: 'own sends get the entrance too');
      expect(opacity!.opacity, lessThan(1));

      await tester.pump(const Duration(milliseconds: 400));
      expect(entranceOf(tester, 'Own hello'), isNull);
    });

    testWidgets('a send settling onto its server id keeps the entrance', (
      tester,
    ) async {
      await pumpChat(tester, 883);
      updates.add({
        '@type': 'updateNewMessage',
        'message': _message(1, 'Own hello', outgoing: true, pending: true),
      });
      await tester.pump();
      await tester.pump();
      expect(entranceOf(tester, 'Own hello'), isNotNull);
      final echoStartedAt = arrivalOf(tester, 'Own hello').startedAt;
      expect(echoStartedAt, isNotNull);

      // The settled message replaces the local echo under a new id, and the
      // row is rebuilt: it must keep finishing the entrance the echo started,
      // which means it has to find that same moment through the local echo id
      // (the id it is keyed by is the server one now).
      updates.add({
        '@type': 'updateMessageSendSucceeded',
        'old_message_id': 1,
        'message': _message(_sentServerId, 'Own hello', outgoing: true),
      });
      await tester.pump();
      await tester.pump();

      final settled = arrivalOf(tester, 'Own hello');
      expect(settled.animate, isTrue);
      expect(
        settled.startedAt,
        echoStartedAt,
        reason: 'the server row continues the entrance the echo started',
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(entranceOf(tester, 'Own hello'), isNull);
      expect(find.text('Own hello', findRichText: true), findsOneWidget);
    });

    testWidgets('an own send from another device rises in as well', (
      tester,
    ) async {
      await pumpChat(tester, 884);
      updates.add({
        '@type': 'updateNewMessage',
        'message': _message(_sentServerId, 'From my laptop', outgoing: true),
      });
      await tester.pump();
      await tester.pump();

      final opacity = entranceOf(tester, 'From my laptop');
      expect(opacity, isNotNull);
      expect(opacity!.opacity, lessThan(1));
    });
  });
}
