import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view.dart'
    show ChatView, clearChatMemoryCaches;
import 'package:mithka/chat/media/file_detail_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/ai_translation/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n_fixtures.dart';

const _chatId = -1001234;
const _messageId = 3;
const _fileId = 5003;
const _fileName = 'app-release.deb';
const _fileSize = 6875944;

Map<String, dynamic> _photoBlock() => {
  '@type': 'pageBlockPhoto',
  'photo': {
    '@type': 'photo',
    'sizes': [
      {
        '@type': 'photoSize',
        'type': 'x',
        'width': 320,
        'height': 240,
        'photo': {'@type': 'file', 'id': 5002, 'unique_id': 'u5002'},
      },
    ],
  },
};

Map<String, dynamic> _documentBlock({String? caption}) => {
  '@type': 'pageBlockDocument',
  'document': {
    '@type': 'document',
    'file_name': _fileName,
    'mime_type': 'application/zip',
    'document': {
      '@type': 'file',
      'id': _fileId,
      'unique_id': 'u$_fileId',
      'size': _fileSize,
    },
  },
  if (caption != null)
    'caption': {
      '@type': 'pageBlockCaption',
      'text': {'@type': 'richTextPlain', 'text': caption},
      'credit': {'@type': 'richTextPlain', 'text': ''},
    },
};

Map<String, dynamic> _richMessageContent({String? caption}) => {
  '@type': 'messageRichMessage',
  'message': {
    '@type': 'richMessage',
    'is_rtl': false,
    'is_full': true,
    'blocks': [
      {
        '@type': 'pageBlockParagraph',
        'text': {'@type': 'richTextPlain', 'text': 'File attached below'},
      },
      _photoBlock(),
      _documentBlock(caption: caption),
    ],
  },
};

/// The shape a channel post takes when a bot sends a rich message with an
/// attachment: the file is a `pageBlockDocument` inside the block tree, not a
/// `messageDocument` content of its own.
Map<String, dynamic> _richMessageJson({String? caption}) => {
  '@type': 'message',
  'id': _messageId,
  'chat_id': _chatId,
  'date': 1700000103,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 7},
  'content': _richMessageContent(caption: caption),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) queryHandler;

  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) => queryHandler(request),
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  late ThemeController theme;
  late TranslationController translation;

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    clearChatMemoryCaches();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: [AppColors.light],
            platform: TargetPlatform.iOS,
          ),
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatView(chatId: _chatId, title: 'Channel'),
        ),
      ),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void installTransport(List<Map<String, dynamic>> page) {
    queryHandler = (request) async {
      switch (request['@type']) {
        case 'getChatHistory':
          return {
            '@type': 'messages',
            'total_count': page.length,
            'messages': page,
          };
        case 'getChat':
          return {
            '@type': 'chat',
            'id': _chatId,
            'title': 'Channel',
            'type': {
              '@type': 'chatTypeSupergroup',
              'supergroup_id': -_chatId - 1000000000000,
              'is_channel': true,
            },
          };
        case 'getSupergroup':
          return {'@type': 'supergroup', 'id': -_chatId - 1000000000000};
        case 'getSupergroupFullInfo':
          return {'@type': 'supergroupFullInfo', 'member_count': 4};
        case 'getMe':
          return {
            '@type': 'user',
            'id': 42,
            'first_name': 'Me',
            'type': {'@type': 'userTypeRegular'},
          };
        case 'getUser':
          return {
            '@type': 'user',
            'id': request['user_id'] ?? 7,
            'first_name': 'User ${request['user_id'] ?? 7}',
            'type': {'@type': 'userTypeRegular'},
          };
        case 'getFile':
          return {
            '@type': 'file',
            'id': request['file_id'],
            'size': _fileSize,
            'expected_size': _fileSize,
            'local': {
              '@type': 'localFile',
              'is_downloading_completed': true,
              'downloaded_size': _fileSize,
              'path': '/tmp/rich-document-$_fileName',
            },
          };
        default:
          return {'@type': 'ok'};
      }
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    theme = ThemeController(await SharedPreferences.getInstance());
    translation = TranslationController(await SharedPreferences.getInstance());
  });

  tearDown(() async {
    clearChatMemoryCaches();
    translation.dispose();
  });

  test('a rich message document block parses into a document block', () {
    final content = _richMessageContent();
    final blocks = TDParse.richMessageBlocks(content);
    expect(blocks, hasLength(3));
    final document = blocks.last;
    expect(document.kind, RichMessageBlockKind.document);
    expect(document.document?.fileName, _fileName);
    expect(document.document?.size, _fileSize);
    expect(document.document?.ext, 'DEB');
    expect(document.document?.file?.id, _fileId);

    // An uncaptioned file still names itself in the preview text.
    expect(TDParse.richMessageDisplayText(content), contains(_fileName));
  });

  test('a captioned document block reports the caption as its text', () {
    final blocks = TDParse.richMessageBlocks(
      _richMessageContent(caption: 'Release build'),
    );
    expect(blocks.last.caption, 'Release build');
    expect(
      TDParse.richMessageDisplayText(
        _richMessageContent(caption: 'Release build'),
      ),
      contains('Release build'),
    );
  });

  testWidgets('the transcript shows the rich message file and opens it', (
    tester,
  ) async {
    installTransport([_richMessageJson()]);
    await pumpChat(tester);

    // The paragraph still renders (mobile selection paints it as a RichText,
    // not a Text)…
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is RichText &&
            w.text.toPlainText().contains('File attached below'),
      ),
      findsOneWidget,
    );
    // …and so does the file attachment that used to be dropped.
    expect(
      find.byKey(const ValueKey('messageDocumentAlbumCard-3')),
      findsOneWidget,
    );
    expect(find.text(_fileName), findsOneWidget);
    expect(find.text('6.6 MB'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('messageDocumentAlbumFile-3')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final detail = find.byType(FileDetailView);
    expect(detail, findsOneWidget);
    expect(tester.widget<FileDetailView>(detail).doc.fileName, _fileName);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  });
}
