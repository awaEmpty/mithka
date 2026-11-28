//
//  topic_badge_timestamp_clearance_test.dart
//
//  In a topics-enabled bot chat's "All topics" transcript the topic section
//  badge sits directly under the previous message. Messages used to hang their
//  detail timestamp BELOW the bubble (a floating row the badge could paint
//  over); the time now lives inside the bubble, so a following row can never
//  reach it. This suite pins both halves: the stamp is inside its bubble, and
//  no badge plate overlaps a stamp.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/channels/topic_navigation.dart';
import 'package:mithka/channels/topic_tabs_placement.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = 700;
const _botUserId = 42;
const _topicA = 61474;
const _topicB = 61753;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => _response(request),
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
  });

  testWidgets('topic section badges clear the previous message timestamp', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({
      'alwaysShowMessageTime': true,
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
          home: const ChatView(chatId: _chatId, title: 'Topic Bot'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 2));

    final headerFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Padding &&
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'forum-topic-section-',
          ),
    );
    final timestampFinder = find.byKey(
      const ValueKey('messageTappedTimestamp'),
      skipOffstage: false,
    );
    final pills = <Rect>[];
    for (final element in headerFinder.evaluate()) {
      final key = (element.widget.key as ValueKey<String>).value;
      // The visible plate, not the full-width row wrapper.
      pills.add(
        tester.getRect(
          find.byKey(
            ValueKey(
              key.replaceFirst(
                'forum-topic-section-',
                'forum-topic-section-tap-',
              ),
            ),
          ),
        ),
      );
    }
    final stamps = <Rect>[
      for (final element in timestampFinder.evaluate())
        tester.getRect(find.byElementPredicate((e) => e == element)),
    ];

    // Both topic runs render a badge and every message keeps its always-on
    // detail timestamp; without that the checks below would pass vacuously.
    expect(pills, hasLength(2));
    expect(stamps, hasLength(4));

    for (final pill in pills) {
      for (final stamp in stamps) {
        final overlap = pill.intersect(stamp);
        expect(
          overlap.width <= 0 || overlap.height <= 0,
          isTrue,
          reason:
              'the topic badge $pill paints over the message timestamp $stamp '
              '(overlap $overlap)',
        );
      }
    }

    // Every stamp is inside a message bubble now, so the clearance above is
    // structural rather than a padding coincidence. Pin that too: a stamp
    // that drifted outside its bubble would make the no-overlap check pass
    // for the wrong reason on this fixture.
    final bubbles = <Rect>[
      for (final element
          in find
              .byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key as ValueKey<String>).value.startsWith(
                      'messageTextBubble-',
                    ),
              )
              .evaluate())
        tester.getRect(find.byElementPredicate((e) => e == element)),
    ];
    expect(bubbles, isNotEmpty);
    for (final stamp in stamps) {
      expect(
        bubbles.any(
          (bubble) =>
              bubble.contains(stamp.topLeft) &&
              bubble.contains(stamp.bottomRight),
        ),
        isTrue,
        reason: 'stamp $stamp must live inside one of $bubbles',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  });

  // exteraless keeps a per-chat tabs position: a bot forum can walk its topic
  // strip from under the header to the side dock and then above the composer,
  // and the choice sticks.
  testWidgets('topic tabs walk top, side, composer and remember', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    TopicTabsPlacementStore.shared.resetForTesting();

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
          home: const ChatView(chatId: _chatId, title: 'Topic Bot'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 2));

    final strip = find.byType(TopicTabStrip);
    expect(strip, findsOneWidget);
    final headerSide = tester.getRect(strip);
    expect(headerSide.top, lessThan(200));

    // exteraless's first step docks the tabs at the conversation's side.
    await tester.tap(find.byKey(const ValueKey('topic-tabs-placement-toggle')));
    await tester.pump();
    expect(find.byType(TopicTabStrip), findsNothing);
    final sideBar = tester.getRect(find.byType(TopicTabsSideBar));
    expect(sideBar.width, 64);
    expect(sideBar.left, 0);
    expect(prefs.getString('mithka.topicTabsPlacement.v1.0.$_chatId'), 'side');

    // The side bar's own control continues to the composer.
    await tester.tap(find.byKey(const ValueKey('topic-tabs-placement-toggle')));
    await tester.pump();

    final composerSide = tester.getRect(strip);
    expect(
      composerSide.top,
      greaterThan(headerSide.top + 200),
      reason: 'the strip must move down to sit above the composer',
    );
    // And it really is above the composer, not under it.
    expect(composerSide.bottom, lessThan(844));
    expect(
      prefs.getString('mithka.topicTabsPlacement.v1.0.$_chatId'),
      'bottom',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  });
}

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'getChat' => {
        '@type': 'chat',
        'id': _chatId,
        'title': 'Topic Bot',
        'type': {'@type': 'chatTypePrivate', 'user_id': _botUserId},
        'permissions': {
          '@type': 'chatPermissions',
          'can_send_basic_messages': true,
        },
      },
      'getUser' => {
        '@type': 'user',
        'id': _botUserId,
        'first_name': 'Topic',
        'last_name': 'Bot',
        'type': {'@type': 'userTypeBot', 'has_topics': true},
      },
      'getSupergroup' => {
        '@type': 'error',
        'message': 'chat not found',
        'code': 400,
      },
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Me'},
      'getConnectionState' => {'@type': 'connectionStateReady'},
      'getForumTopics' => {
        '@type': 'forumTopics',
        'topics': [
          _topic(_topicA, '项目组讨论与技术方案评审', _message(10, 'A first')),
          _topic(_topicB, '产品反馈与建议收集', _message(12, 'B first')),
        ],
      },
      'getChatHistory' => {'@type': 'messages', 'messages': _history},
      'getMessage' => _message(request['message_id'] as int, 'Fetched'),
      _ => {'@type': 'ok'},
    };

Map<String, dynamic> _topic(
  int id,
  String name,
  Map<String, dynamic> lastMessage,
) => {
  '@type': 'forumTopic',
  'info': {
    '@type': 'forumTopicInfo',
    'chat_id': _chatId,
    'forum_topic_id': id,
    'name': name,
  },
  'last_message': lastMessage,
};

/// Oldest first: two topics, an incoming and an outgoing message in each.
final List<Map<String, dynamic>> _history = [
  _message(10, 'A first', topicId: _topicA),
  _message(11, 'A second', topicId: _topicA, outgoing: true),
  _message(12, 'B first', topicId: _topicB),
  _message(13, 'B second', topicId: _topicB, outgoing: true),
];

Map<String, dynamic> _message(
  int id,
  String text, {
  int? topicId,
  bool outgoing = false,
}) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1700000000 + id,
  'is_outgoing': outgoing,
  'sender_id': {
    '@type': 'messageSenderUser',
    'user_id': outgoing ? 1 : _botUserId,
  },
  if (topicId != null)
    'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': topicId},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text},
  },
};
