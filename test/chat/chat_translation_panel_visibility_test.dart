// Regression: the chat-level translation bar ("translate this chat") is a
// transcript control, not part of the topic strip. 3e5ecce54 moved it into
// `_topicTabStrip`, whose early return skips every ordinary chat — so the bar
// vanished from private chats and groups, and from wide split shells.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/ai_translation/chat_translation_language_cache.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const privateChatId = 4242;
const peerUserId = 7001;
const _meUserId = 7002;

const _translationChannel = MethodChannel('mithka/native_translation');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getChat' => {
            '@type': 'chat',
            'id': privateChatId,
            'title': 'English friend',
            'type': {'@type': 'chatTypePrivate', 'user_id': peerUserId},
            'permissions': {
              '@type': 'chatPermissions',
              'can_send_basic_messages': true,
            },
            'last_read_inbox_message_id': 1,
          },
          'getUser' => {
            '@type': 'user',
            'id': request['user_id'] ?? peerUserId,
            'first_name': 'Ann',
            'type': {'@type': 'userTypeRegular'},
          },
          'getMe' => {
            '@type': 'user',
            'id': _meUserId,
            'first_name': 'Me',
            'type': {'@type': 'userTypeRegular'},
          },
          'getChatHistory' => {
            '@type': 'messages',
            'total_count': 3,
            'messages': [
              _incomingMessage(1),
              _incomingMessage(2),
              _incomingMessage(3),
            ],
          },
          'getOption' => {'@type': 'optionValueInteger', 'value': '1024'},
          'getCountries' => {'@type': 'countries', 'countries': const []},
          'getCurrentState' => {'@type': 'ok'},
          'getBotApiAccountInfo' => {'@type': 'ok'},
          _ => {'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    updates.add({
      '@type': 'updateConnectionState',
      'state': {'@type': 'connectionStateReady'},
    });
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  setUp(() {
    ChatHeaderStateCache.resetForTesting();
    ChatTranslationLanguageCache.shared.resetForTesting();
    // Native language identification answers off the platform thread in
    // production; a mock handler is what makes that round-trip resolve inside
    // a widget test. 'en' is what turns the suggestion into a visible bar.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_translationChannel, (call) async {
          return switch (call.method) {
            'capabilities' => <String>[],
            'identifyLanguage' => {'languageCode': 'en', 'confidence': 0.9},
            _ => null,
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_translationChannel, null);
  });

  testWidgets('an ordinary chat still shows the chat translation bar', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    final locale = AppLocaleController(prefs);
    final accounts = AccountStore(prefs);
    final auth = AuthManager();
    final translation = TranslationController(prefs);
    final drawer = dc.DrawerController();
    addTearDown(theme.dispose);
    addTearDown(locale.dispose);
    addTearDown(accounts.dispose);
    addTearDown(auth.dispose);
    addTearDown(translation.dispose);
    addTearDown(drawer.dispose);

    // A private chat is not a forum: `_topicsKnown` is false, so the topic
    // strip never builds — the bar has to come from the transcript column.
    expect(translation.translateChats, isTrue);
    expect(translation.autoTranslateEnabledFor(privateChatId), isFalse);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<AppLocaleController>.value(value: locale),
          ChangeNotifierProvider<AccountStore>.value(value: accounts),
          ChangeNotifierProvider<AuthManager>.value(value: auth),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
          ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
        ],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.light,
            extensions: [AppColors.light],
          ),
          home: const ChatView(chatId: privateChatId, title: 'English friend'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('chat-translation-panel')),
      findsOneWidget,
    );

    // Flush ChatView's 5s read-sync timer before the pending-timer invariant.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}

Map<String, dynamic> _incomingMessage(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': privateChatId,
  'date': 1785862260 + id,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': peerUserId},
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'Good morning number $id, how are you doing today?',
      'entities': <Object>[],
    },
  },
};
