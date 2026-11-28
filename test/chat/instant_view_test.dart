//
//  instant_view_test.dart
//
//  Native Instant View: page-block parsing, the local-first loader, the reader
//  widget (article, details disclosure, error/retry, RTL) and the link preview
//  badge that opens it.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/instant_view/instant_view_loader.dart';
import 'package:mithka/chat/instant_view/instant_view_models.dart';
import 'package:mithka/chat/instant_view/instant_view_view.dart';
import 'package:mithka/chat/links_search/link_handler.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _plain(String text) => {
  '@type': 'richTextPlain',
  'text': text,
};

Map<String, dynamic> _paragraph(String text) => {
  '@type': 'pageBlockParagraph',
  'text': _plain(text),
};

Map<String, dynamic> _pageJson({bool rtl = false}) => {
  '@type': 'webPageInstantView',
  'blocks': [
    {
      '@type': 'pageBlockCover',
      'cover': {'@type': 'pageBlockUnsupported'},
    },
    {'@type': 'pageBlockKicker', 'kicker': _plain('Story')},
    {'@type': 'pageBlockTitle', 'title': _plain('Telegraph story')},
    {
      '@type': 'pageBlockAuthorDate',
      'author': _plain('Ann Author'),
      'publish_date': 1700000000,
    },
    {
      '@type': 'pageBlockParagraph',
      'text': {
        '@type': 'richTexts',
        'texts': [
          _plain('Hello '),
          {'@type': 'richTextBold', 'text': _plain('world')},
          {
            '@type': 'richTextUrl',
            'text': _plain(' example'),
            'url': 'https://example.com/story',
            'is_cached': false,
          },
        ],
      },
    },
    {
      '@type': 'pageBlockList',
      'items': [
        {
          'label': '',
          'blocks': [_paragraph('First item')],
          'has_checkbox': false,
          'is_checked': false,
          'value': 1,
          'type': '1',
        },
        {
          'label': '',
          'blocks': [_paragraph('Done item')],
          'has_checkbox': true,
          'is_checked': true,
          'value': 0,
          'type': '*',
        },
      ],
    },
    {'@type': 'pageBlockAnchor', 'name': 'details'},
    {
      '@type': 'pageBlockDetails',
      'header': _plain('Read more'),
      'blocks': [_paragraph('Hidden paragraph')],
      'is_open': false,
    },
    {
      '@type': 'pageBlockTable',
      'caption': _plain(''),
      'cells': [
        [
          {
            'text': _plain('Name'),
            'is_header': true,
            'colspan': 2,
            'rowspan': 1,
            'align': {'@type': 'pageBlockHorizontalAlignmentLeft'},
            'valign': {'@type': 'pageBlockVerticalAlignmentTop'},
          },
        ],
        [
          {
            'text': _plain('A'),
            'is_header': false,
            'colspan': 1,
            'rowspan': 1,
            'align': {'@type': 'pageBlockHorizontalAlignmentCenter'},
            'valign': {'@type': 'pageBlockVerticalAlignmentMiddle'},
          },
          {
            'text': _plain('B'),
            'is_header': false,
            'colspan': 1,
            'rowspan': 1,
            'align': {'@type': 'pageBlockHorizontalAlignmentRight'},
            'valign': {'@type': 'pageBlockVerticalAlignmentBottom'},
          },
        ],
      ],
      'is_bordered': true,
      'is_striped': true,
      'is_compact': false,
    },
    {
      '@type': 'pageBlockRelatedArticles',
      'header': _plain('Related'),
      'articles': [
        {
          'url': 'https://telegra.ph/other',
          'title': 'Another story',
          'description': 'Second article',
          'photo': null,
          'author': 'Bob',
          'publish_date': 1700000001,
        },
      ],
    },
    {'@type': 'pageBlockUnsupported'},
  ],
  'view_count': 42,
  'version': 2,
  'is_rtl': rtl,
  'is_full': true,
  'feedback_link': {'@type': 'internalLinkTypeNone'},
};

class _FakeSource implements InstantViewSource {
  _FakeSource({this.page, this.fail = false, this.localMiss = false});

  InstantViewPage? page;
  bool fail;

  /// Simulates a page TDLib has not cached yet: the local read misses and
  /// only the network read answers.
  bool localMiss;
  final List<bool> localCalls = [];
  var fetches = 0;

  @override
  Future<InstantViewPage> fetch(String url, {required bool onlyLocal}) async {
    fetches++;
    localCalls.add(onlyLocal);
    if (fail || (onlyLocal && localMiss)) {
      throw InstantViewUnavailable(url);
    }
    final page = this.page;
    if (page == null) throw InstantViewUnavailable(url);
    if (onlyLocal && page.isEmpty) throw InstantViewUnavailable(url);
    return page;
  }
}

Future<void> _pumpReader(
  WidgetTester tester, {
  required InstantViewLoader loader,
  InstantViewPage? initialPage,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: InstantViewView(
          url: 'https://telegra.ph/story',
          loader: loader,
          initialPage: initialPage,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('parses the page-block tree Telegram serves for an article', () {
    final page = InstantViewPage.parse(_pageJson());
    expect(page.version, 2);
    expect(page.viewCount, 42);
    expect(page.isFull, isTrue);
    expect(page.blocks.length, 11);
    expect(page.blocks[2], isA<IvTitleBlock>());
    expect(
      ivTextToPlain((page.blocks[2] as IvTitleBlock).title),
      'Telegraph story',
    );
    final paragraph = page.blocks[4] as IvParagraphBlock;
    expect(ivTextToPlain(paragraph.text), 'Hello world example');
    final list = page.blocks[5] as IvListBlock;
    expect(list.items.length, 2);
    expect(list.items[0].value, 1);
    expect(list.items[1].hasCheckbox, isTrue);
    expect(list.items[1].isChecked, isTrue);
    final details = page.blocks[7] as IvDetailsBlock;
    expect(details.isOpen, isFalse);
    expect(details.blocks.single, isA<IvParagraphBlock>());
    final table = page.blocks[8] as IvTableBlock;
    expect(table.cells.length, 2);
    expect(table.cells[0].single.colspan, 2);
    expect(table.cells[0].single.isHeader, isTrue);
    expect(table.cells[1][1].align, IvAlign.right);
    final related = page.blocks[9] as IvRelatedArticlesBlock;
    expect(related.articles.single.title, 'Another story');
    expect(page.blocks[10], isA<IvUnsupportedBlock>());
  });

  test('link preview versions expose the badge only for real pages', () {
    MessageLinkPreview preview(int version) => MessageLinkPreview(
      url: 'https://telegra.ph/x',
      displayUrl: 'telegra.ph/x',
      siteName: 'Telegraph',
      title: 'Title',
      description: '',
      instantViewVersion: version,
    );
    expect(preview(0).hasInstantView, isFalse);
    expect(preview(2).hasInstantView, isTrue);
  });

  test('telegraph-style links try the Instant View first', () {
    expect(instantViewTryFirst('https://telegra.ph/a-story'), isTrue);
    expect(instantViewTryFirst('https://te.legra.ph/a'), isTrue);
    expect(instantViewTryFirst('https://graph.org/a'), isTrue);
    expect(instantViewTryFirst('https://telegram.org/blog/update'), isTrue);
    expect(instantViewTryFirst('https://telegram.org/tos'), isFalse);
    expect(instantViewTryFirst('https://t.me/iv?url=x'), isTrue);
    expect(instantViewTryFirst('https://twitter.com/a/status/1'), isFalse);
    expect(instantViewTryFirst('https://example.com'), isFalse);
    expect(instantViewTryFirst('not a url'), isFalse);
  });

  test('loader prefers the local copy and caches the result', () async {
    final source = _FakeSource(page: InstantViewPage.parse(_pageJson()));
    final loader = InstantViewLoader(source: source);
    final first = await loader.load('https://telegra.ph/story/');
    expect(source.localCalls, [true]);
    expect(loader.cached('https://telegra.ph/story'), same(first));
    final second = await loader.load('https://telegra.ph/story#part');
    expect(second, same(first));
    expect(source.fetches, 1);
  });

  test(
    'loader falls back to the network and dedupes concurrent reads',
    () async {
      final source = _FakeSource(
        page: InstantViewPage.parse(_pageJson()),
        localMiss: true,
      );
      final loader = InstantViewLoader(source: source);
      final results = await Future.wait([
        loader.load('https://telegra.ph/story'),
        loader.load('https://telegra.ph/story'),
      ]);
      expect(source.localCalls, [true, false]);
      expect(source.fetches, 2);
      expect(results[0], same(results[1]));
    },
  );

  test('loader reports pages Telegram cannot instant-view', () async {
    final source = _FakeSource(fail: true);
    final loader = InstantViewLoader(source: source);
    await expectLater(
      loader.load('https://example.com/none'),
      throwsA(isA<InstantViewUnavailable>()),
    );
    expect(source.localCalls, [true, false]);
  });

  testWidgets('renders the article, disclosure and related stories', (
    tester,
  ) async {
    final page = InstantViewPage.parse(_pageJson());
    final loader = InstantViewLoader(source: _FakeSource(page: page));
    await _pumpReader(tester, loader: loader, initialPage: page);

    expect(find.text('Telegraph story', findRichText: true), findsWidgets);
    expect(
      find.text('Hello world example', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('First item', findRichText: true), findsOneWidget);
    expect(find.text('Done item', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('instantViewArticle')), findsOneWidget);
    expect(find.text('Hidden paragraph', findRichText: true), findsNothing);

    await tester.tap(find.text('Read more', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Hidden paragraph', findRichText: true), findsOneWidget);

    expect(find.text('Related', findRichText: true), findsOneWidget);
    expect(find.text('Another story', findRichText: true), findsOneWidget);
  });

  testWidgets('a failed load offers retry and recovers', (tester) async {
    final source = _FakeSource(fail: true);
    final loader = InstantViewLoader(source: source);
    await _pumpReader(tester, loader: loader);

    expect(find.text('Couldn’t load this page'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);

    source
      ..fail = false
      ..page = InstantViewPage.parse(_pageJson());
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Telegraph story', findRichText: true), findsWidgets);
    expect(find.text('Couldn’t load this page'), findsNothing);
  });

  testWidgets('honours the article direction', (tester) async {
    final page = InstantViewPage.parse(_pageJson(rtl: true));
    final loader = InstantViewLoader(source: _FakeSource(page: page));
    await _pumpReader(tester, loader: loader, initialPage: page);

    final directions = tester
        .widgetList<Directionality>(find.byType(Directionality))
        .map((widget) => widget.textDirection);
    expect(directions, contains(TextDirection.rtl));
  });

  testWidgets('searches the article and counts matches', (tester) async {
    final page = InstantViewPage.parse(_pageJson());
    final loader = InstantViewLoader(source: _FakeSource(page: page));
    await _pumpReader(tester, loader: loader, initialPage: page);

    await tester.tap(find.byKey(const ValueKey('instantViewSearchAction')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('instantViewSearchField')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('instantViewSearchField')),
      'hello',
    );
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('instantViewSearchField')),
      'nothing-here',
    );
    await tester.pumpAndSettle();
    expect(find.text('0/0'), findsOneWidget);
  });

  testWidgets('adjusts and persists the article text size', (tester) async {
    final page = InstantViewPage.parse(_pageJson());
    final loader = InstantViewLoader(source: _FakeSource(page: page));
    await _pumpReader(tester, loader: loader, initialPage: page);

    await tester.tap(find.byKey(const ValueKey('instantViewTextSizeAction')));
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('instantViewTextSizeSlider'));
    expect(slider, findsOneWidget);

    await tester.drag(slider, const Offset(80, 0));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('instantViewFontSize.v1'), isNotNull);
    expect(prefs.getDouble('instantViewFontSize.v1')!, greaterThan(16));
  });

  testWidgets('a preview with an Instant View carries the badge', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);
    ChatMessage message({required int version}) => ChatMessage(
      id: 7,
      isOutgoing: false,
      text: 'https://telegra.ph/story',
      date: 1700000000,
      contentType: 'messageText',
      linkPreview: MessageLinkPreview(
        url: 'https://telegra.ph/story',
        displayUrl: 'telegra.ph/story',
        siteName: 'Telegraph',
        title: 'Telegraph story',
        description: 'A story',
        instantViewVersion: version,
      ),
    );

    Future<void> pump(int version) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeController>.value(
          value: theme,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: MessageBubble(
                  message: message(version: version),
                  peerTitle: 'Chat',
                  isGroup: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    await pump(2);
    expect(
      find.byKey(const ValueKey('messageInstantViewBadge-7')),
      findsOneWidget,
    );
    expect(find.text('Instant view'), findsOneWidget);

    await pump(0);
    expect(
      find.byKey(const ValueKey('messageInstantViewBadge-7')),
      findsNothing,
    );
  });
}
