//
//  chat_translate_all_visibility_test.dart
//
//  The chat-level "translate to <language>" command is a promise that the
//  transcript will change. exteraless decides it from per-message language
//  evidence (TranslateController.checkDialogTranslatable): at least three
//  checked messages, at least 60% of the classified ones translatable, and
//  fewer than 65% undetectable. A chat in the target language therefore
//  carries no Translate entry, and neither does one whose language is unknown
//  or mixed too heavily.
//

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
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = 771002;
const _peerUserId = 7711;
const _meUserId = 7712;

const _translationChannel = MethodChannel('mithka/native_translation');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<Map<String, dynamic>> updates;
  var chatId = _chatId;
  var nextChatId = _chatId;
  final messageTexts = <String>[];
  String? Function(String text) detectedLanguageFor = (_) => null;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async => switch (request['@type']) {
          'getChat' => {
            '@type': 'chat',
            'id': chatId,
            'title': 'Language chat',
            'type': {'@type': 'chatTypePrivate', 'user_id': _peerUserId},
            'permissions': {
              '@type': 'chatPermissions',
              'can_send_basic_messages': true,
            },
            'last_read_inbox_message_id': 1,
          },
          'getUser' => {
            '@type': 'user',
            'id': request['user_id'] ?? _peerUserId,
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
            'total_count': messageTexts.length,
            'messages': [
              for (var index = 0; index < messageTexts.length; index++)
                {
                  '@type': 'message',
                  'id': 10 + index,
                  'chat_id': chatId,
                  'date': 1785862260 + index,
                  'is_outgoing': false,
                  'sender_id': {
                    '@type': 'messageSenderUser',
                    'user_id': _peerUserId,
                  },
                  'content': {
                    '@type': 'messageText',
                    'text': {
                      '@type': 'formattedText',
                      'text': messageTexts[index],
                    },
                  },
                  'reply_to': {'@type': 'messageReplyToMessage', 'chat_id': 0},
                },
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
    chatId = ++nextChatId;
    messageTexts.clear();
    detectedLanguageFor = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_translationChannel, (call) async {
          return switch (call.method) {
            'capabilities' => <String>[],
            'identifyLanguage' => switch (detectedLanguageFor(
              call.arguments is Map
                  ? (call.arguments as Map)['text']?.toString() ?? ''
                  : '',
            )) {
              final language? => {'languageCode': language, 'confidence': 0.9},
              null => null,
            },
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_translationChannel, null);
  });

  Future<void> openChat(
    WidgetTester tester, {
    void Function(TranslationController translation)? configure,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    configure?.call(translation);

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
          home: ChatView(chatId: chatId, title: 'Language chat'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('chatHeaderMenu')));
    await tester.pumpAndSettle();
  }

  Future<void> closeChat(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }

  Finder translateRow() =>
      find.byKey(const ValueKey('app-anchored-menu-translate'));

  testWidgets('a chat already in the target language offers no translate-all', (
    tester,
  ) async {
    // ML Kit answers `zh` for Chinese; the target is `zh-Hans`. exteraless
    // treats both as the user's own language and never offers the button.
    messageTexts.addAll(const [
      '这是一条完全用中文写成的消息，用来让语言识别返回中文。',
      '这是第二条中文消息，长度足够做语言识别。',
      '这是第三条中文消息，长度足够做语言识别。',
    ]);
    detectedLanguageFor = (_) => 'zh';
    await openChat(tester);

    expect(
      find.byKey(const ValueKey('chat-translation-panel')),
      findsNothing,
      reason: 'no suggestion bar in a chat that needs no translation',
    );
    await openMenu(tester);
    expect(translateRow(), findsNothing);
    await closeChat(tester);
  });

  testWidgets('a foreign-language chat offers translate-all and the bar', (
    tester,
  ) async {
    messageTexts.addAll(const [
      'This message is written in English so detection says so.',
      'Another English sentence, long enough to be identified.',
      'A third English sentence for the three-message threshold.',
    ]);
    detectedLanguageFor = (_) => 'en';
    await openChat(tester);

    expect(
      find.byKey(const ValueKey('chat-translation-panel')),
      findsOneWidget,
    );
    await openMenu(tester);
    expect(translateRow(), findsOneWidget);
    await closeChat(tester);
  });

  testWidgets('a mixed chat below the 60% ratio offers nothing', (
    tester,
  ) async {
    messageTexts.addAll(const [
      'This message is written in English.',
      'Another English sentence.',
      '这是一条中文消息。',
      '这是另一条中文消息。',
    ]);
    detectedLanguageFor = (text) => text.contains('English') ? 'en' : 'zh';
    await openChat(tester);
    expect(find.byKey(const ValueKey('chat-translation-panel')), findsNothing);
    await openMenu(tester);
    expect(translateRow(), findsNothing);
    await closeChat(tester);
  });

  testWidgets('a mixed chat at the 60% ratio offers translate-all', (
    tester,
  ) async {
    messageTexts.addAll(const [
      'This message is written in English.',
      'Another English sentence.',
      'A third English sentence.',
      '这是一条中文消息。',
      '这是另一条中文消息。',
    ]);
    detectedLanguageFor = (text) => text.contains('English') ? 'en' : 'zh';
    await openChat(tester);
    expect(
      find.byKey(const ValueKey('chat-translation-panel')),
      findsOneWidget,
    );
    await openMenu(tester);
    expect(translateRow(), findsOneWidget);
    await closeChat(tester);
  });

  testWidgets('an unknown chat language does not invent a translate-all', (
    tester,
  ) async {
    messageTexts.addAll(const [
      '12345 67890 12345 67890 12345',
      '09876 54321 09876 54321 09876',
      '11111 22222 33333 44444 55555',
    ]);
    detectedLanguageFor = (_) => null;
    await openChat(tester);

    expect(find.byKey(const ValueKey('chat-translation-panel')), findsNothing);
    await openMenu(tester);
    expect(translateRow(), findsNothing);
    await closeChat(tester);
  });

  testWidgets('hiding the suggestion bar keeps the menu command reachable', (
    tester,
  ) async {
    messageTexts.addAll(const [
      'This message is written in English.',
      'Another English sentence.',
      'A third English sentence.',
    ]);
    detectedLanguageFor = (_) => 'en';
    await openChat(
      tester,
      configure: (translation) =>
          translation.dismissAutoTranslateSuggestionFor(chatId),
    );

    expect(find.byKey(const ValueKey('chat-translation-panel')), findsNothing);
    await openMenu(tester);
    expect(translateRow(), findsOneWidget);
    await closeChat(tester);
  });

  testWidgets('an active translation keeps its off switch in any language', (
    tester,
  ) async {
    messageTexts.addAll(const [
      '这是一条中文消息，用户仍然显式开启了翻译。',
      '这是第二条中文消息。',
      '这是第三条中文消息。',
    ]);
    detectedLanguageFor = (_) => 'zh';
    await openChat(
      tester,
      configure: (translation) =>
          translation.setAutoTranslateEnabledFor(chatId, true),
    );

    expect(
      find.byKey(const ValueKey('chat-translation-panel')),
      findsOneWidget,
    );
    // Translations arrive per viewport now, so the bar carries no "working"
    // spinner: it always keeps the language glyph.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-translation-panel')),
        matching: find.byType(AppActivityIndicator),
      ),
      findsNothing,
    );
    await openMenu(tester);
    expect(translateRow(), findsOneWidget);
    await closeChat(tester);
  });
}
