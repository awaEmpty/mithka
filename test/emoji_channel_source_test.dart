import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/emoji_channel_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(paths, (call) async => '/tmp');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(paths, null);
  });

  group('parseCatalog', () {
    test('parses the exteraless-shaped catalog message', () {
      const body =
          '#emojiv2\n'
          '{\n'
          '    "emojis": [\n'
          '        {"name": "Apple", "version": 2, "id": "apple", "preview": 22, "file": 23},\n'
          '        {"name": "Twemoji", "version": 2, "id": "twemoji", "preview": 48, "file": 49}\n'
          '    ]\n'
          '}';
      final entries = EmojiChannelSource.parseCatalog(body);
      expect(entries, isNotNull);
      expect(entries!.map((e) => e.key), ['apple', 'twemoji']);
      final apple = entries.first;
      expect(apple.label, 'Apple');
      expect(apple.channelMessageId, 23);
      expect(apple.channelPreviewMessageId, 22);
      expect(apple.isChannelServed, isTrue);
      expect(apple.extension, 'ttf');
    });

    test('a pack served as a zip remembers both addresses', () {
      const body =
          '#emojiv2 {"emojis": [{"name": "Apple", "id": "apple", '
          '"preview": 22, "file": 23, "zip": 60, "size": 41943040}]}';
      final apple = EmojiChannelSource.parseCatalog(body)!.single;
      expect(apple.channelMessageId, 23);
      expect(apple.channelArchiveMessageId, 60);
      expect(apple.isArchive, isTrue);
      expect(apple.sizeBytes, 41943040);

      const plain =
          '#emojiv2 {"emojis": [{"name": "X", "id": "x", "file": 7}]}';
      final x = EmojiChannelSource.parseCatalog(plain)!.single;
      expect(x.channelArchiveMessageId, isNull);
      expect(x.isArchive, isFalse);
    });

    test('entries without a preview id keep a null preview id', () {
      const body =
          '#emojiv2 {"emojis": [{'
          '"name": "X", "id": "x", "file": 7}]}';
      final entries = EmojiChannelSource.parseCatalog(body);
      expect(entries?.single.channelPreviewMessageId, isNull);
    });

    test('rejects a body without the tag or json', () {
      expect(EmojiChannelSource.parseCatalog('hello'), isNull);
      expect(EmojiChannelSource.parseCatalog('#emojiv2 no braces'), isNull);
    });

    test('rejects entries without a usable file id', () {
      const body = '#emojiv2 {"emojis": [{"name": "X", "id": "x", "file": 0}]}';
      expect(EmojiChannelSource.parseCatalog(body), isNull);
    });
  });

  group('fetchCatalog', () {
    test('resolves the channel, searches and stamps the chat id', () async {
      final calls = <Map<String, dynamic>>[];
      final source = EmojiChannelSource(
        client: _ScriptedTdClient((request) async {
          calls.add(Map<String, dynamic>.from(request));
          switch (request['@type']) {
            case 'searchPublicChat':
              return {
                '@type': 'chat',
                'id': '-3778471221',
                'type': {'@type': 'chatTypeSupergroup'},
              };
            case 'searchChatMessages':
              if (request['query'] != '#emojiv2') {
                return {'@type': 'messages', 'total_count': 0, 'messages': []};
              }
              if (request['chat_id'] != -3778471221) {
                return {'@type': 'messages', 'total_count': 0, 'messages': []};
              }
              return {
                '@type': 'messages',
                'total_count': 1,
                'messages': [
                  {
                    '@type': 'message',
                    'id': 50,
                    'content': {
                      '@type': 'messageText',
                      'text': {
                        '@type': 'formattedText',
                        'text':
                            '#emojiv2 {"emojis": [{"name": "Fluent 3D", '
                            '"id": "fluent", "preview": 42, "file": 43, '
                            '"zip": 46, "size": 39196420}]}',
                      },
                    },
                  },
                ],
              };
          }
          return {'@type': 'ok'};
        }),
      );
      final entries = await source.fetchCatalog();
      expect(entries, isNotNull);
      expect(entries!.single.key, 'fluent');
      expect(entries.single.chatId, -3778471221);
      expect(entries.single.channelMessageId, 43);
      expect(
        entries.single.channelArchiveMessageId,
        46,
        reason: 'the archive address must survive the chat-id stamp',
      );
      expect(entries.single.sizeBytes, 39196420);
      expect(
        calls.map((c) => c['@type']),
        containsAll(['searchPublicChat', 'searchChatMessages']),
      );
    });

    test('returns null when no account client is active', () async {
      final inactive = EmojiChannelSource(client: _NoClientTdClient());
      expect(await inactive.fetchCatalog(), isNull);
    });

    test('returns null when the search finds no catalog message', () async {
      final source = EmojiChannelSource(
        client: _ScriptedTdClient((request) async {
          switch (request['@type']) {
            case 'searchPublicChat':
              return {
                '@type': 'chat',
                'id': '-100',
                'type': {'@type': 'chatTypeSupergroup'},
              };
            case 'searchChatMessages':
              return {'@type': 'messages', 'total_count': 0, 'messages': []};
          }
          return {'@type': 'ok'};
        }),
      );
      expect(await source.fetchCatalog(), isNull);
    });
  });

  group('downloadFont', () {
    test(
      'walks message → document → downloadFile and copies to dest',
      () async {
        final tmpDir = await Directory.systemTemp.createTemp('emoji_channel');
        addTearDown(() => tmpDir.delete(recursive: true));
        final fakeTdPath = '${tmpDir.path}/td-cache.ttf';
        File(fakeTdPath).writeAsBytesSync(List.filled(64, 9), flush: true);
        final destPath = '${tmpDir.path}/dest.ttf';

        final source = EmojiChannelSource(
          client: _ScriptedTdClient((request) async {
            switch (request['@type']) {
              case 'searchPublicChat':
                return {'@type': 'chat', 'id': '-1'};
              case 'getMessages':
                final ids = request['message_ids'] as List?;
                if (ids == null || ids.length != 1 || ids[0] != (43 << 20)) {
                  return {'@type': 'messages', 'messages': []};
                }
                return {
                  '@type': 'messages',
                  'messages': [
                    {
                      '@type': 'message',
                      'id': 43 << 20,
                      'content': {
                        '@type': 'messageDocument',
                        'document': {
                          '@type': 'document',
                          'mime_type': 'font/ttf',
                          // TDLib keeps the download file one level deeper:
                          // document.document is the `file` with id/size.
                          'document': {
                            '@type': 'file',
                            'id': 7777,
                            'expected_size': 64,
                          },
                        },
                      },
                    },
                  ],
                };
              case 'downloadFile':
                if (request['file_id'].toString() != '7777') {
                  return {
                    '@type': 'file',
                    'id': 7777,
                    'local': {
                      '@type': 'localFile',
                      'path': '',
                      'is_downloading_completed': false,
                    },
                  };
                }
                // Real TDLib: downloadFile with synchronous: false accepts the
                // transfer and reports completion via getFile, not inline.
                if (request['synchronous'] == true) {
                  return {
                    '@type': 'file',
                    'id': 7777,
                    'local': {
                      '@type': 'localFile',
                      'path': fakeTdPath,
                      'is_downloading_completed': true,
                    },
                  };
                }
                return {
                  '@type': 'file',
                  'id': 7777,
                  'local': {
                    '@type': 'localFile',
                    'path': '',
                    'is_downloading_completed': false,
                  },
                };
              case 'getFile':
                return {
                  '@type': 'file',
                  'id': 7777,
                  'local': {
                    '@type': 'localFile',
                    'path': fakeTdPath,
                    'is_downloading_completed': true,
                  },
                };
            }
            return {'@type': 'ok'};
          }),
        );

        final bytes = await source.downloadFont(
          chatId: -1,
          messageId: 43,
          destPath: destPath,
        );
        expect(bytes, 64);
        expect(File(destPath).lengthSync(), 64);
      },
    );

    test(
      'downloadPreview rejects a non-image document and succeeds on PNGs',
      () async {
        final tmpDir = await Directory.systemTemp.createTemp('emoji_prev');
        addTearDown(() => tmpDir.delete(recursive: true));
        File('${tmpDir.path}/td.png').writeAsBytesSync(List.filled(32, 1));
        String mimeFor(int id) => id == (90 << 20) ? 'image/png' : 'font/ttf';
        final source = EmojiChannelSource(
          client: _ScriptedTdClient((request) async {
            switch (request['@type']) {
              case 'getMessages':
                final ids = request['message_ids'] as List;
                final id = ids[0] as int;
                return {
                  '@type': 'messages',
                  'messages': [
                    {
                      '@type': 'message',
                      'id': id,
                      'content': {
                        '@type': 'messageDocument',
                        'document': {
                          '@type': 'document',
                          'mime_type': mimeFor(id),
                          'document': {
                            '@type': 'file',
                            'id': 5000 + id,
                            'expected_size': 32,
                          },
                        },
                      },
                    },
                  ],
                };
              case 'downloadFile':
                // Real TDLib: synchronous: false accepts the transfer and
                // reports completion via getFile.
                return {
                  '@type': 'file',
                  'local': {
                    '@type': 'localFile',
                    'path': '',
                    'is_downloading_completed': false,
                  },
                };
              case 'getFile':
                return {
                  '@type': 'file',
                  'local': {
                    '@type': 'localFile',
                    'path': '${tmpDir.path}/td.png',
                    'is_downloading_completed': true,
                  },
                };
            }
            return {'@type': 'ok'};
          }),
        );
        // A font message where a preview should be: refused, no file written.
        expect(
          await source.downloadPreview(
            chatId: -1,
            messageId: 43,
            destPath: '${tmpDir.path}/bad.png',
          ),
          isNull,
        );
        expect(File('${tmpDir.path}/bad.png').existsSync(), isFalse);
        // A real preview PNG downloads and lands on disk.
        expect(
          await source.downloadPreview(
            chatId: -1,
            messageId: 90,
            destPath: '${tmpDir.path}/good.png',
          ),
          32,
        );
      },
    );

    test(
      'document fetches use a TDLib method that actually exists (regression: '
      'getChatMessages is not in the TDLib schema — real TDLib answered '
      'error and every font/preview download failed)',
      () async {
        final seenMethods = <String>[];
        final source = EmojiChannelSource(
          client: _ScriptedTdClient((request) async {
            seenMethods.add(request['@type'] as String);
            switch (request['@type']) {
              case 'getMessages':
                return {
                  '@type': 'messages',
                  'messages': [
                    {
                      '@type': 'message',
                      'id': 43 << 20,
                      'content': {
                        '@type': 'messageDocument',
                        'document': {
                          '@type': 'document',
                          'mime_type': 'font/ttf',
                          'document': {
                            '@type': 'file',
                            'id': 7777,
                            'expected_size': 8,
                          },
                        },
                      },
                    },
                  ],
                };
              case 'downloadFile':
                return {'@type': 'error', 'code': 400, 'message': 'stop'};
            }
            return {'@type': 'ok'};
          }),
        );
        // downloadFont surfaces null on failure; the point here is the METHOD
        // it tried: anything but getMessages means real TDLib would error out.
        await source.downloadFont(
          chatId: -1,
          messageId: 43,
          destPath: '/tmp/wont-write.ttf',
        );
        expect(seenMethods.first, 'getMessages');
        expect(seenMethods, isNot(contains('getChatMessages')));
      },
    );
  });
}

typedef _Handler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class _ScriptedTdClient implements TdClient {
  _ScriptedTdClient(this.handler);

  final _Handler handler;

  @override
  int get activeClientId => 1;

  @override
  bool get hasActiveClient => true;

  @override
  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request, {
    Duration timeout = TdClient.defaultQueryTimeout,
  }) => handler(request);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoClientTdClient implements TdClient {
  @override
  bool get hasActiveClient => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
