//
//  Channel post counters are only as fresh as the last time TDLib was asked
//  about the post. `viewMessages` is that ask — TDLib answers it with
//  `messages.getMessagesViews` and publishes the fresh numbers as
//  `updateMessageInteractionInfo`. The transcript therefore reports every
//  channel post that enters the viewport, its own posts included, and reports
//  a post again after it scrolled away and came back.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/chat_unread_progress.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channelId = -1004242;
const _supergroupId = 4242;

Future<Map<String, dynamic>> Function(Map<String, dynamic>) _query =
    (_) async => <String, dynamic>{'@type': 'ok'};
Future<void> Function(Map<String, dynamic>) _send = (_) async {};
final _requests = <Map<String, dynamic>>[];

/// One post per message id, newest first like TDLib's history page.
Map<String, dynamic> _post(int id, {bool outgoing = false}) => {
  '@type': 'message',
  'id': id,
  'chat_id': _channelId,
  'date': 1700000000 + id,
  'is_outgoing': outgoing,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': 'post $id'},
  },
  'interaction_info': {
    '@type': 'messageInteractionInfo',
    'view_count': 1234,
    'forward_count': 56,
    'reply_info': null,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final updates = StreamController<Map<String, dynamic>>.broadcast();

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) => _query(request),
        send: (request) => _send(request),
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  group('viewport report bookkeeping', () {
    test('a post is reported once per stay on screen', () {
      final progress = ChatUnreadProgress();
      expect(progress.markChannelPostReported(messageId: 7), isTrue);
      expect(
        progress.markChannelPostReported(messageId: 7),
        isFalse,
        reason: 'a post that stays in the viewport must not be re-requested',
      );

      // Leaves the viewport: nothing visible, so the report is forgotten.
      progress.retainVisibleChannelPosts(const <int>{});
      expect(
        progress.markChannelPostReported(messageId: 7),
        isTrue,
        reason: 'scrolling back to a post refreshes its counters again',
      );
    });

    test('a post that stays visible keeps its report', () {
      final progress = ChatUnreadProgress();
      progress.markChannelPostReported(messageId: 9);
      progress.retainVisibleChannelPosts(const {9, 10});
      expect(progress.markChannelPostReported(messageId: 9), isFalse);
    });
  });

  group('reportChannelPostViews', () {
    setUp(() {
      _requests.clear();
      _query = (_) async => <String, dynamic>{'@type': 'ok'};
      _send = (request) async => _requests.add(request);
    });

    test('reports the visible posts in one counter-only request', () async {
      final viewModel = ChatViewModel(
        chatId: _channelId,
        title: 'Channel',
        markReadOnOpen: false,
      );
      addTearDown(viewModel.dispose);

      viewModel.reportChannelPostViews([
        ChatMessage(id: 501, text: 'incoming', date: 1, isOutgoing: false),
        // The account's own posts never took the read path, so their counters
        // used to freeze at whatever the first history page carried.
        ChatMessage(id: 502, text: 'own post', date: 2, isOutgoing: true),
        ChatMessage(
          id: 503,
          text: 'service',
          date: 3,
          isOutgoing: false,
          isService: true,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(_requests, [
        {
          '@type': 'viewMessages',
          'chat_id': _channelId,
          'message_ids': [501, 502],
          'source': {'@type': 'messageSourceOther'},
          'force_read': false,
        },
      ]);
    });

    test('sends nothing when no post qualifies', () async {
      final viewModel = ChatViewModel(
        chatId: _channelId,
        title: 'Channel',
        markReadOnOpen: false,
      );
      addTearDown(viewModel.dispose);

      viewModel.reportChannelPostViews([
        ChatMessage(
          id: 601,
          text: 'service',
          date: 1,
          isOutgoing: false,
          isService: true,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(_requests, isEmpty);
    });
  });

  testWidgets('a channel transcript reports the posts it puts on screen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    _requests.clear();
    _send = (request) async => _requests.add(request);
    _query = (request) async {
      switch (request['@type']) {
        case 'getChat':
          return {
            '@type': 'chat',
            'id': _channelId,
            'type': {
              '@type': 'chatTypeSupergroup',
              'supergroup_id': _supergroupId,
              'is_channel': true,
            },
            'title': 'Channel',
            'unread_count': 0,
          };
        case 'getSupergroup':
          return {
            '@type': 'supergroup',
            'id': _supergroupId,
            'is_channel': true,
            'member_count': 10,
            'status': {'@type': 'chatMemberStatusMember'},
          };
        case 'getChatHistory':
          if (request['only_local'] == true) {
            return {'@type': 'messages', 'messages': []};
          }
          return {
            '@type': 'messages',
            'messages': [
              // The newest post is the account's own.
              _post(7042, outgoing: true),
              _post(7041),
              _post(7040),
            ],
          };
        default:
          return {'@type': 'ok'};
      }
    };

    SharedPreferences.setMockInitialValues({});
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
          home: const ChatView(chatId: _channelId, title: 'Channel'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final reports = _requests
        .where(
          (request) =>
              request['@type'] == 'viewMessages' &&
              request['source'] is Map &&
              (request['source'] as Map)['@type'] == 'messageSourceOther',
        )
        .toList();
    expect(
      reports,
      isNotEmpty,
      reason: 'a channel transcript must ask TDLib for its posts\' counters',
    );
    final reportedIds = {
      for (final report in reports)
        ...(report['message_ids'] as List).cast<int>(),
    };
    expect(
      reportedIds,
      containsAll(<int>[7042, 7041, 7040]),
      reason: 'the posts on screen, the account\'s own newest post included',
    );
    for (final report in reports) {
      expect(report['chat_id'], _channelId);
      expect(report['force_read'], isFalse);
      expect(report['source'], {'@type': 'messageSourceOther'});
    }
    expect(
      reports.length,
      lessThan(3),
      reason: 'layout passes repeat; the counter ask must not',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
