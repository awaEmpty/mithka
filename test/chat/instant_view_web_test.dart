import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/instant_view/instant_view_models.dart';
import 'package:mithka/chat/instant_view/instant_view_web.dart';

Map<String, dynamic> _page(List<dynamic> content) => {
  'title': 'Telegram (software)',
  'siteName': 'Wikipedia',
  'content': content,
};

void main() {
  group('web Instant View JSON', () {
    test('turns the extractor output into article blocks', () {
      final page = parseWebInstantViewPage(
        _page([
          {
            'tag': 'div',
            'content': [
              {
                'tag': 'p',
                'content': [
                  'Telegram is a ',
                  {
                    'tag': 'a',
                    'href': 'https://en.wikipedia.org/wiki/Cloud',
                    'content': ['cloud-based'],
                  },
                  ' service with ',
                  {
                    'tag': 'b',
                    'content': ['secret chats'],
                  },
                  {
                    'tag': 'sup',
                    'content': [
                      {
                        'tag': 'a',
                        'href': '#cite-1',
                        'content': ['[1]'],
                      },
                    ],
                  },
                  '.',
                ],
              },
              {
                'tag': 'h3',
                'content': ['History'],
              },
              {
                'tag': 'ul',
                'content': [
                  {
                    'tag': 'li',
                    'content': ['First item'],
                  },
                  {
                    'tag': 'li',
                    'content': ['Second item'],
                  },
                ],
              },
            ],
          },
          {'tag': 'hr'},
          {
            'tag': 'pre',
            'content': ['final answer = 42;\nreturn answer;'],
          },
          {
            'tag': 'blockquote',
            'content': [
              {
                'tag': 'p',
                'content': ['Quoted text'],
              },
            ],
          },
          {
            'tag': 'figure',
            'content': [
              {
                'tag': 'img',
                'src': 'https://upload.wikimedia.org/telegram.png',
                'width': '250',
                'height': '140',
                'alt': 'Telegram logo',
              },
              {
                'tag': 'figcaption',
                'content': ['The logo'],
              },
            ],
          },
          {
            'tag': 'table',
            'content': [
              {
                'tag': 'tbody',
                'content': [
                  {
                    'tag': 'tr',
                    'content': [
                      {
                        'tag': 'th',
                        'content': ['Release'],
                      },
                      {
                        'tag': 'th',
                        'content': ['Date'],
                      },
                    ],
                  },
                  {
                    'tag': 'tr',
                    'content': [
                      {
                        'tag': 'td',
                        'content': ['1.0'],
                      },
                      {
                        'tag': 'td',
                        'content': ['2013'],
                      },
                    ],
                  },
                ],
              },
            ],
          },
          {
            'tag': 'details',
            'content': [
              {
                'tag': 'summary',
                'content': ['References'],
              },
              {
                'tag': 'p',
                'content': ['Source list'],
              },
            ],
          },
          {
            'tag': 'img',
            'src': 'https://upload.wikimedia.org/edit.png',
            'width': '10',
            'height': '10',
          },
        ]),
        url: 'https://en.wikipedia.org/wiki/Telegram_(software)',
      );

      expect(page.isFull, isTrue);
      expect(page.blocks.first, isA<IvTitleBlock>());

      final paragraph = page.blocks.whereType<IvParagraphBlock>().first;
      final text = paragraph.text;
      expect(text, isA<IvTextConcat>());
      final runs = (text as IvTextConcat).children;
      expect(
        runs.whereType<IvTextLink>().single.value,
        'https://en.wikipedia.org/wiki/Cloud',
      );
      expect(runs.whereType<IvTextStyled>().first.style, IvTextStyle.bold);
      expect(
        runs.whereType<IvTextStyled>().where(
          (run) => run.style == IvTextStyle.superscript,
        ),
        isNotEmpty,
      );

      expect(page.blocks.whereType<IvSectionHeadingBlock>().single.size, 1);
      final list = page.blocks.whereType<IvListBlock>().single;
      expect(list.items.length, 2);
      expect(page.blocks.whereType<IvDividerBlock>(), hasLength(1));
      expect(
        ivTextToPlain(page.blocks.whereType<IvPreformattedBlock>().single.text),
        'final answer = 42;\nreturn answer;',
      );
      expect(page.blocks.whereType<IvBlockQuoteBlock>(), hasLength(1));

      final photo = page.blocks.whereType<IvPhotoBlock>().single;
      expect(photo.photo.url, 'https://upload.wikimedia.org/telegram.png');
      expect(photo.photo.width, 250);
      expect(ivTextToPlain(photo.caption.text), 'The logo');

      final table = page.blocks.whereType<IvTableBlock>().single;
      expect(table.cells.length, 2);
      expect(table.cells.first.first.isHeader, isTrue);
      expect(ivTextToPlain(table.cells[1][1].text), '2013');

      final details = page.blocks.whereType<IvDetailsBlock>().single;
      expect(ivTextToPlain(details.header), 'References');
      expect(details.blocks, hasLength(1));
    });

    test('flattens unknown containers and keeps relative links absolute', () {
      final page = parseWebInstantViewPage(
        _page([
          {
            'tag': 'section',
            'content': [
              {
                'tag': 'div',
                'content': [
                  {
                    'tag': 'p',
                    'content': [
                      {
                        'tag': 'a',
                        'href': '/wiki/Telegram',
                        'content': ['Telegram'],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ]),
        url: 'https://en.wikipedia.org/wiki/Software',
      );

      final text = page.blocks.whereType<IvParagraphBlock>().single.text;
      final runs = text is IvTextConcat ? text.children : [text];
      final link = runs.whereType<IvTextLink>().single;
      expect(link.value, 'https://en.wikipedia.org/wiki/Telegram');
    });

    test('skips data: placeholders when a srcset is present', () {
      final page = parseWebInstantViewPage(
        _page([
          {
            'tag': 'img',
            'src': 'data:image/gif;base64,R0lGOD',
            'srcset': 'https://upload.wikimedia.org/real.png 2x',
            'width': '300',
            'height': '200',
          },
        ]),
        url: 'https://example.com/article',
      );
      expect(
        page.blocks.whereType<IvPhotoBlock>().single.photo.url,
        'https://upload.wikimedia.org/real.png',
      );
    });

    test('decodes Android and WKWebView JavaScript results', () {
      const json = '{"title":"x","content":[]}';
      expect(decodeInstantViewWebResult(json), isNotNull);
      // Android's evaluateJavascript hands strings back JSON-quoted.
      expect(decodeInstantViewWebResult(jsonEncode(json)), isNotNull);
      expect(decodeInstantViewWebResult('"null"'), isNull);
      expect(decodeInstantViewWebResult('null'), isNull);
      expect(decodeInstantViewWebResult(''), isNull);
      expect(decodeInstantViewWebResult(42), isNull);
    });

    test('a page without content is empty', () {
      final page = parseWebInstantViewPage({
        'title': 'Nothing',
        'content': <dynamic>[],
      }, url: 'https://example.com/empty');
      expect(page.blocks.whereType<IvTitleBlock>(), hasLength(1));
      expect(page.blocks.length, 1);
    });
  });
}
