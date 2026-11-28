//
//  Mirror for the messages this account received: deleted and edited ones
//  stay readable. Every observation runs against a store whose TDLib wiring
//  is replaced by a broadcast controller, so updates are injected directly.
//
//  Records are owned by the account whose client produced the update:
//  injected updates carry '@client_id' (as every real TDLib update does) and
//  a stub resolver maps client ids to account user ids.
//
//  The suite needs the feature compiled in
//  (--dart-define=I_DONT_FUCKING_CARE_ABOUT_TOS=true); without it the store
//  is a no-op by design, so the whole file skips.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/media/media_prefetch.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/history/message_history_settings.dart';
import 'package:mithka/history/message_history_store.dart';
import 'package:mithka/history/message_media_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = allowTelegramTosViolations;

/// Client id used by the pre-account tests' updates; resolved to 7001.
const _clientA = 101;
const _accountA = 7001;
const _clientB = 202;
const _accountB = 7002;

/// Stub per-client identity mapping; a missing client resolves to null so
/// its updates are dropped instead of misattributed.
class _StubResolver implements TosAccountUserIdResolver {
  _StubResolver(this.ids);

  final Map<int, int?> ids;

  @override
  Future<int?> resolve(int clientId) async => ids[clientId];
}

/// Stub resolver whose per-client lookups complete only when the test
/// releases the held completer, so interleavings around identity resolution
/// become deterministic.
class _GatedResolver implements TosAccountUserIdResolver {
  _GatedResolver(this.ids);

  final Map<int, Completer<int?>> ids;

  @override
  Future<int?> resolve(int clientId) => ids[clientId]!.future;
}

/// A `file` object whose local copy is fully on disk.
Map<String, dynamic> _completeFile(int id, String path) => {
  '@type': 'file',
  'id': id,
  'local': {
    '@type': 'localFile',
    'path': path,
    'is_downloading_completed': true,
    'is_active_downloading': false,
  },
};

Map<String, dynamic> _message(
  int chatId,
  int messageId, {
  String text = 'hello',
  int date = 1700000000,
  int senderId = 42,
}) => {
  '@type': 'message',
  'chat_id': '$chatId',
  'id': messageId,
  'date': date,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': '$senderId'},
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text},
  },
};

/// Stands in for the prefetcher: records what the mirror asks for instead of
/// talking to TDLib.
class _RecordingPrefetch extends MediaPrefetch {
  final contents = <Map<String, dynamic>?>[];

  @override
  Future<int> prefetchTdContent(Map<String, dynamic>? content) async {
    contents.add(content);
    return 0;
  }
}

Map<String, dynamic> _photoMessage(
  int chatId,
  int messageId, {
  String caption = '',
  int fileId = 501,
}) => {
  '@type': 'message',
  'chat_id': '$chatId',
  'id': messageId,
  'date': 1700000000,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': '42'},
  'content': {
    '@type': 'messagePhoto',
    'caption': {'@type': 'formattedText', 'text': caption},
    'photo': {
      '@type': 'photo',
      'sizes': [
        {
          '@type': 'photoSize',
          'photo': {'@type': 'file', 'id': fileId, 'size': 4096},
        },
      ],
    },
  },
};

void main() {
  if (!_enabled) {
    return;
  }

  late Directory dir;
  late StreamController<Map<String, dynamic>> updates;
  late StreamController<int> activeSlotChanges;
  late MessageHistoryStore store;
  late _RecordingPrefetch prefetch;
  late int notifications;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mithka-history-test');
    updates = StreamController<Map<String, dynamic>>.broadcast();
    activeSlotChanges = StreamController<int>.broadcast();
    store = MessageHistoryStore.forTesting();
    store.fileDir = dir;
    store.updateSource = (_) => updates.stream;
    store.activeSlotChangeSource = () => activeSlotChanges.stream;
    store.accountUserIdResolver = _StubResolver({
      _clientA: _accountA,
      _clientB: _accountB,
    });
    store.activeClientIdProvider = () => _clientA;
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    // Recording is off by default; these tests exercise the store with
    // every chat type recorded.
    MessageHistorySettings.shared
      ..initialize(prefs)
      ..setEnableAll(true)
      ..setRecordDeleted(true)
      ..setRecordEdits(true)
      ..setRecordPrivate(true)
      ..setRecordGroups(true)
      ..setRecordChannels(true)
      ..setSnapshotPrivate(true);
    store.initialize(prefs);
    prefetch = _RecordingPrefetch();
    MediaPrefetch.debugInstance = prefetch;
    notifications = 0;
    store.addListener(() => notifications++);
  });

  tearDown(() async {
    MediaPrefetch.debugInstance = null;
    store.dispose();
    await updates.close();
    await activeSlotChanges.close();
    await dir.delete(recursive: true);
    // Reset the runtime switches for the next suite (defaults are OFF).
    final settings = MessageHistorySettings.shared;
    settings.setEnableAll(false);
    settings.setRecordDeleted(false);
    settings.setRecordEdits(false);
    settings.setSnapshotPrivate(false);
  });

  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> start() async {
    store.startObserving();
    await pump();
  }

  /// Emits an update stamped with the TDLib client that observed it, the
  /// way every real update arrives.
  void emitAs(int clientId, String type, Map<String, dynamic> update) =>
      updates.add({'@type': type, '@client_id': clientId, ...update});

  Map<String, dynamic> persistedJson() {
    final file = File('${dir.path}/message-history.json');
    expect(file.existsSync(), isTrue, reason: 'mirror file was never written');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  test(
    'a refetched message refreshes content without losing its history',
    () async {
      await start();
      store.recordIncomingMessage(_message(11, 100, text: 'before'));
      emitAs(_clientA, 'updateMessageEdited', {
        'chat_id': '11',
        'message_id': 100,
        'edit_date': 123,
      });
      emitAs(_clientA, 'updateMessageContent', {
        'chat_id': '11',
        'message_id': 100,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'edited'},
        },
      });
      await pump();
      store.recordIncomingMessage({
        ..._message(11, 100),
        'content': {
          '@type': 'messagePhoto',
          'caption': {'@type': 'formattedText', 'text': 'refetched caption'},
        },
      });
      final entry = store.entry(11, 100)!;
      expect(entry.text, 'refetched caption');
      expect(entry.kindKey, 'historyKindPhoto');
      expect(entry.events.single.oldText, 'before');
      expect(entry.events.single.newText, 'edited');
    },
  );

  test('a replaced picture records a revision with the same caption', () async {
    // Editing a photo in place (crop, sticker over it) keeps the caption and
    // the kind: only the file id moves. That edit used to be dropped on the
    // floor, so long-press had no "view edits" entry to offer.
    await start();
    store.recordIncomingMessage(
      _photoMessage(11, 100, caption: 'same caption'),
    );
    emitAs(_clientA, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 100,
      'edit_date': 123,
    });
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messagePhoto',
        'caption': {'@type': 'formattedText', 'text': 'same caption'},
        'photo': {
          '@type': 'photo',
          'sizes': [
            {
              '@type': 'photoSize',
              'photo': {'@type': 'file', 'id': 777, 'size': 4096},
            },
          ],
        },
      },
    });
    await pump();
    final entry = store.entry(11, 100)!;
    expect(entry.events, hasLength(1));
    expect(entry.events.single.oldText, 'same caption');
    expect(entry.events.single.newText, 'same caption');
    expect(entry.mediaFileId, 777, reason: 'the entry follows the new picture');
  });

  test('a caption-only edit stays a single revision', () async {
    await start();
    store.recordIncomingMessage(_photoMessage(11, 101, caption: 'old'));
    emitAs(_clientA, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 101,
      'edit_date': 124,
    });
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 101,
      'new_content': {
        '@type': 'messagePhoto',
        'caption': {'@type': 'formattedText', 'text': 'new'},
        'photo': {
          '@type': 'photo',
          'sizes': [
            {
              '@type': 'photoSize',
              'photo': {'@type': 'file', 'id': 501, 'size': 4096},
            },
          ],
        },
      },
    });
    await pump();
    final entry = store.entry(11, 101)!;
    expect(entry.events, hasLength(1));
    expect(entry.mediaFileId, 501);
  });

  test('a recorded photo with no file on disk is prefetched', () async {
    // Half of the snapshot problem: in a chat the user never opens, no row
    // ever asks for the picture, so the mirror must ask itself.
    await start();
    store.recordIncomingMessage(_photoMessage(11, 102, caption: 'hi'));
    await pump();
    expect(prefetch.contents, hasLength(1));
    expect(prefetch.contents.single?['@type'], 'messagePhoto');
  });

  test('incoming messages mirror with sender, kind and text', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();
    await store.persistNowForTesting();

    final entries = store.entries;
    expect(entries, hasLength(1));
    expect(entries.single.chatId, 11);
    expect(entries.single.messageId, 100);
    expect(entries.single.senderId, 42);
    expect(entries.single.date, 1700000000);
    expect(entries.single.text, 'hello');
    expect(entries.single.kindKey, isEmpty);
    expect(entries.single.state, MessageHistoryState.active);
    expect(persistedJson()['entries'], hasLength(1));
  });

  test('updateDeleteMessages keeps the copy and marks it deleted', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'secret'),
    });
    await pump();
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();

    final entry = store.entry(11, 100);
    expect(entry, isNotNull);
    expect(entry!.state, MessageHistoryState.deleted);
    expect(entry.deletedAt, greaterThan(0));
    expect(entry.text, 'secret');

    await store.persistNowForTesting();
    final state = (persistedJson()['entries'] as List).single;
    expect(state['state'], 'deleted');
    expect(state['text'], 'secret');
  });

  test('cache unloads and inaccessible messages are not deletions', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'still there'),
    });
    await pump();

    // TDLib reports "removed from the local cache, may be retrieved again".
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': false,
      'from_cache': true,
    });
    await pump();
    expect(store.entry(11, 100)!.state, MessageHistoryState.active);

    // ... and messages that merely became inaccessible for this account.
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': false,
      'from_cache': false,
    });
    await pump();
    expect(store.entry(11, 100)!.state, MessageHistoryState.active);
    expect(store.entry(11, 100)!.deletedAt, 0);
  });

  test('live evidence reactivates a wrongly recorded deletion', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'v1'),
    });
    await pump();
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();
    expect(store.entry(11, 100)!.state, MessageHistoryState.deleted);

    // A transcript that parsed the live message hands it back to the mirror.
    final before = notifications;
    store.confirmAlive(_accountA, 11, 100);
    await pump();
    final entry = store.entry(11, 100)!;
    expect(entry.state, MessageHistoryState.active);
    expect(entry.deletedAt, 0);
    // One notification for the batch, not one per parsed message.
    expect(notifications - before, 1);
  });

  test('historyEntries lists only deleted or edited copies', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'ordinary'),
    });
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 101, text: 'gone'),
    });
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 102, text: 'before edit'),
    });
    await pump();
    emitAs(_clientA, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 102,
      'edit_date': 1700000123,
    });
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 102,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'after edit'},
      },
    });
    emitAs(_clientA, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['101'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();
    store.debugSetActiveAccount(_accountA);

    expect(store.entries, hasLength(3));
    final history = store.historyEntries.map((e) => e.messageId).toSet();
    expect(history, {101, 102});
    expect(store.historyEntriesFor(11), hasLength(2));
  });

  test('a photo keeps the size that is already on disk', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-thumb.jpg')
      ..writeAsBytesSync(List.filled(6, 1));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 410),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 1280,
                'height': 960,
                'photo': {
                  '@type': 'file',
                  'id': 21,
                  'local': {
                    '@type': 'localFile',
                    'path': '',
                    'is_downloading_completed': false,
                    'is_active_downloading': false,
                  },
                },
              },
              {
                '@type': 'photoSize',
                'width': 320,
                'height': 240,
                'photo': {
                  '@type': 'file',
                  'id': 22,
                  'local': {
                    '@type': 'localFile',
                    'path': source.path,
                    'is_downloading_completed': true,
                    'is_active_downloading': false,
                  },
                },
              },
            ],
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(11, 410)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(11, 410)!;
    expect(entry.mediaPath, isNotEmpty);
    expect(entry.mediaWidth, 320);
    expect(entry.mediaHeight, 240);
    expect(entry.mediaFileId, 22);
    expect(File(entry.mediaPath).lengthSync(), 6);
  });

  test(
    'a download that finishes later is snapshotted via updateFile',
    () async {
      final media = MessageMediaSnapshotter.forTesting();
      media.dir = dir;
      store.mediaSnapshotter = media;
      final source = File('${dir.path}/tdlib-cache-late.jpg')
        ..writeAsBytesSync(List.filled(9, 2));
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': {
          ..._message(11, 411),
          'content': {
            '@type': 'messagePhoto',
            'photo': {
              '@type': 'photo',
              'sizes': [
                {
                  '@type': 'photoSize',
                  'width': 800,
                  'height': 600,
                  'photo': {
                    '@type': 'file',
                    'id': 31,
                    'local': {
                      '@type': 'localFile',
                      'path': '',
                      'is_downloading_completed': false,
                      'is_active_downloading': false,
                    },
                  },
                },
              ],
            },
          },
        },
      });
      await pump();
      expect(store.entry(11, 411)!.mediaPath, isEmpty);

      // The bubble asked for the size; TDLib reports the completed file.
      emitAs(_clientA, 'updateFile', {
        'file': {
          '@type': 'file',
          'id': 31,
          'size': 9,
          'expected_size': 9,
          'local': {
            '@type': 'localFile',
            'path': source.path,
            'is_downloading_completed': true,
            'is_active_downloading': false,
            'downloaded_size': 9,
          },
        },
      });
      for (var i = 0; i < 100; i++) {
        if ((store.entry(11, 411)?.mediaPath ?? '').isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final entry = store.entry(11, 411)!;
      expect(entry.mediaPath, isNotEmpty);
      expect(entry.mediaWidth, 800);
      expect(entry.mediaHeight, 600);
      expect(File(entry.mediaPath).lengthSync(), 9);
    },
  );

  test('a larger size upgrades the earlier snapshot', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final small = File('${dir.path}/tdlib-cache-small.jpg')
      ..writeAsBytesSync(List.filled(5, 3));
    final large = File('${dir.path}/tdlib-cache-large.jpg')
      ..writeAsBytesSync(List.filled(11, 4));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 412),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 1600,
                'height': 1200,
                'photo': {
                  '@type': 'file',
                  'id': 41,
                  'local': {
                    '@type': 'localFile',
                    'path': '',
                    'is_downloading_completed': false,
                    'is_active_downloading': false,
                  },
                },
              },
              {
                '@type': 'photoSize',
                'width': 400,
                'height': 300,
                'photo': {
                  '@type': 'file',
                  'id': 42,
                  'local': {
                    '@type': 'localFile',
                    'path': small.path,
                    'is_downloading_completed': true,
                    'is_active_downloading': false,
                  },
                },
              },
            ],
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(11, 412)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final first = store.entry(11, 412)!;
    expect(first.mediaWidth, 400);
    expect(File(first.mediaPath).lengthSync(), 5);

    emitAs(_clientA, 'updateFile', {
      'file': {
        '@type': 'file',
        'id': 41,
        'size': 11,
        'expected_size': 11,
        'local': {
          '@type': 'localFile',
          'path': large.path,
          'is_downloading_completed': true,
          'is_active_downloading': false,
          'downloaded_size': 11,
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if (store.entry(11, 412)!.mediaWidth == 1600) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final upgraded = store.entry(11, 412)!;
    expect(upgraded.mediaWidth, 1600);
    expect(upgraded.mediaHeight, 1200);
    expect(upgraded.mediaPath, first.mediaPath);
    expect(File(upgraded.mediaPath).lengthSync(), 11);
  });

  test('content changes without a preceding edit produce nothing', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'v1'),
    });
    await pump();
    emitAs(_clientA, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'v2'},
      },
    });
    await pump();

    final entry = store.entry(11, 100)!;
    expect(entry.isEdited, isFalse);
    expect(entry.text, 'v1');
  });

  test(
    'a deleted message that comes back is active again, history intact',
    () async {
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'v1'),
      });
      await pump();
      emitAs(_clientA, 'updateDeleteMessages', {
        'chat_id': '11',
        'message_ids': ['100'],
        'is_permanent': true,
        'from_cache': false,
      });
      await pump();
      emitAs(_clientA, 'updateNewMessage', {
        'message': _message(11, 100, text: 'v1'),
      });
      await pump();

      final entry = store.entry(11, 100)!;
      expect(entry.state, MessageHistoryState.active);
      expect(entry.deletedAt, 0);
    },
  );

  test('an excluded chat records nothing', () async {
    await start();
    store.excludeChat(11);
    await pump();

    emitAs(_clientA, 'updateNewMessage', {'message': _message(11, 100)});
    await pump();

    expect(store.entries, isEmpty);
    expect(store.isChatExcluded(11), isTrue);
  });

  test('persisted copies load back', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'kept'),
    });
    await pump();
    await store.persistNowForTesting();

    // A fresh instance must read what the first one wrote; the original is
    // left alive for tearDown to dispose.
    final revived = MessageHistoryStore.forTesting();
    revived.fileDir = dir;
    addTearDown(revived.dispose);
    await revived.ensureLoaded();
    expect(revived.entryCount, 1);
    revived.debugSetActiveAccount(_accountA);
    expect(revived.entry(11, 100)!.text, 'kept');
  });

  // ---------------------------------------------------------------------------
  // Account ownership
  // ---------------------------------------------------------------------------

  test('deletions from one account mark only that account’s copy', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from A'),
    });
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from B'),
    });
    await pump();

    emitAs(_clientB, 'updateDeleteMessages', {
      'chat_id': '11',
      'message_ids': ['100'],
      'is_permanent': true,
      'from_cache': false,
    });
    await pump();

    store.debugSetActiveAccount(_accountA);
    expect(store.entry(11, 100)!.state, MessageHistoryState.active);
    expect(store.entry(11, 100)!.deletedAt, 0);

    store.debugSetActiveAccount(_accountB);
    expect(store.entry(11, 100)!.state, MessageHistoryState.deleted);
    expect(store.entry(11, 100)!.deletedAt, greaterThan(0));
  });

  test('removeAccount forgets that account and keeps the others', () async {
    await start();
    emitAs(_clientA, 'updateNewMessage', {'message': _message(12, 200)});
    emitAs(_clientB, 'updateNewMessage', {'message': _message(11, 100)});
    emitAs(_clientB, 'updateMessageEdited', {
      'chat_id': '11',
      'message_id': 100,
      'edit_date': 1700000123,
    });
    await pump();

    store.debugSetActiveAccount(_accountA);
    store.excludeChat(22);
    store.debugSetActiveAccount(_accountB);
    store.excludeChat(33);
    await pump();

    store.removeAccount(_accountB);

    expect(store.entryCount, 1);
    store.debugSetActiveAccount(_accountA);
    expect(store.entries.single.chatId, 12);
    store.debugSetActiveAccount(_accountB);
    expect(store.entries, isEmpty);
    expect(store.isChatExcluded(33), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey('messageHistory.excludedChats.v2.$_accountB'),
      isFalse,
    );
    expect(prefs.getStringList('messageHistory.excludedChats.v2.$_accountA'), [
      '22',
    ]);

    // B's pending edit dates died with the account: a late content update
    // produces nothing instead of touching a re-registered account's copy.
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'fresh'),
    });
    await pump();
    emitAs(_clientB, 'updateMessageContent', {
      'chat_id': '11',
      'message_id': 100,
      'new_content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'orphan edit'},
      },
    });
    await pump();
    store.debugSetActiveAccount(_accountB);
    final entry = store.entry(11, 100)!;
    expect(entry.text, 'fresh');
    expect(entry.isEdited, isFalse);
  });

  // ---------------------------------------------------------------------------
  // Pending-work invalidation, arrival ordering, failed resolutions
  // (second review round)
  // ---------------------------------------------------------------------------

  test('a failing resolution drops the updates and later ones retry', () async {
    final gates = {_clientA: Completer<int?>(), _clientB: Completer<int?>()};
    store.accountUserIdResolver = _GatedResolver(gates);
    await start();
    gates[_clientA]!.complete(_accountA);
    await pump();

    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'from B'),
    });
    await pump();
    // Failing the first lookup drops that client's queued events; nothing
    // may be written, guessed or partially recorded.
    gates[_clientB]!.completeError(StateError('getMe lost'));
    await pump();
    await pump();
    expect(store.entryCount, 0);
    expect(store.entries, isEmpty);

    // The next event starts a fresh resolution attempt.
    gates[_clientB] = Completer<int?>()..complete(_accountB);
    emitAs(_clientB, 'updateNewMessage', {
      'message': _message(11, 100, text: 'second attempt'),
    });
    await pump();
    await pump();
    store.debugSetActiveAccount(_accountB);
    expect(store.entry(11, 100)!.text, 'second attempt');
  });

  // ---------------------------------------------------------------------------
  // Scoped invalidation (third review round): removing one account or
  // clearing one chat must not cancel unrelated pending work — only the
  // explicitly global operations (clearAll, dispose) invalidate everything.
  // ---------------------------------------------------------------------------

  test(
    'a media file fully on disk is snapshotted into the mirror dir',
    () async {
      final media = MessageMediaSnapshotter.forTesting();
      media.dir = dir;
      store.mediaSnapshotter = media;
      final source = File('${dir.path}/tdlib-cache-photo.jpg')
        ..writeAsBytesSync(List.filled(8, 7));
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': {
          ..._message(11, 400),
          'content': {
            '@type': 'messagePhoto',
            'photo': {
              '@type': 'photo',
              'sizes': [
                {
                  '@type': 'photoSize',
                  'width': 100,
                  'height': 50,
                  'photo': {
                    '@type': 'file',
                    'id': 5,
                    'local': {
                      '@type': 'localFile',
                      'path': source.path,
                      'is_downloading_completed': true,
                      'is_active_downloading': false,
                    },
                  },
                },
              ],
            },
          },
        },
      });
      // The copy runs off the update chain; wait for it deterministically
      // instead of counting microtask pumps.
      // The copy lands on the I/O thread: a fixed count of zero-delay turns
      // runs out on a loaded CI machine, so give it a real-time budget.
      for (var i = 0; i < 100; i++) {
        if ((store.entry(11, 400)?.mediaPath ?? '').isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final entry = store.entry(11, 400)!;
      expect(entry.kindKey, 'historyKindPhoto');
      expect(entry.mediaPath, isNotEmpty);
      expect(File(entry.mediaPath).existsSync(), isTrue);
      // clearing the chat deletes the snapshot file too
      store.debugSetActiveAccount(_accountA);
      store.clearChat(11);
      expect(File(entry.mediaPath).existsSync(), isFalse);
    },
  );
  test('a messageAudio file is snapshotted too', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-song.mp3')
      ..writeAsBytesSync(List.filled(8, 3));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 402),
        'content': {
          '@type': 'messageAudio',
          'audio': {
            '@type': 'audio',
            'audio': {
              '@type': 'file',
              'id': 7,
              'local': {
                '@type': 'localFile',
                'path': source.path,
                'is_downloading_completed': true,
                'is_active_downloading': false,
              },
            },
          },
        },
      },
    });
    // Same real-time budget as the photo case above.
    for (var i = 0; i < 100; i++) {
      if ((store.entry(11, 402)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(11, 402)!;
    expect(entry.kindKey, 'historyKindAudio');
    expect(entry.mediaPath, isNotEmpty);
    expect(File(entry.mediaPath).existsSync(), isTrue);
  });

  // TDLib's `@type` wrappers nest the file one level down. A copy taken from
  // the wrapper itself has no local path and silently never snapshots — the
  // ghost then kept showing "Document"/"Video" for a file that was on disk.
  test('a document file is snapshotted from document.document', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-report.pdf')
      ..writeAsBytesSync(List.filled(6, 1));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 403),
        'content': {
          '@type': 'messageDocument',
          'document': {
            '@type': 'document',
            'file_name': 'report.pdf',
            'mime_type': 'application/pdf',
            'document': _completeFile(8, source.path),
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(11, 403)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(11, 403)!;
    expect(entry.kindKey, 'historyKindDocument');
    expect(entry.mediaFileName, 'report.pdf');
    expect(entry.mediaPath, isNotEmpty);
    expect(File(entry.mediaPath).lengthSync(), 6);
  });

  test('a video keeps its file and its poster apart', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final video = File('${dir.path}/tdlib-cache-clip.mp4')
      ..writeAsBytesSync(List.filled(9, 2));
    final poster = File('${dir.path}/tdlib-cache-clip.jpg')
      ..writeAsBytesSync(List.filled(3, 4));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 404),
        'content': {
          '@type': 'messageVideo',
          'video': {
            '@type': 'video',
            'width': 640,
            'height': 360,
            'duration': 12,
            'file_name': 'clip.mp4',
            'mime_type': 'video/mp4',
            'video': _completeFile(9, video.path),
            'thumbnail': {
              '@type': 'photoSize',
              'width': 320,
              'height': 180,
              'photo': _completeFile(10, poster.path),
            },
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      final entry = store.entry(11, 404);
      if (entry != null &&
          entry.mediaPath.isNotEmpty &&
          entry.mediaPosterPath.isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(11, 404)!;
    expect(entry.kindKey, 'historyKindVideo');
    expect(entry.mediaPath, isNotEmpty);
    expect(File(entry.mediaPath).lengthSync(), 9);
    expect(entry.mediaPosterPath, isNotEmpty);
    expect(entry.mediaPosterPath, isNot(entry.mediaPath));
    expect(File(entry.mediaPosterPath).lengthSync(), 3);
    expect(entry.mediaWidth, 640);
    expect(entry.mediaDuration, 12);
  });

  test('a sticker is snapshotted from sticker.sticker', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final stickerFile = File('${dir.path}/tdlib-cache-sticker.webp')
      ..writeAsBytesSync(List.filled(4, 6));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 405),
        'content': {
          '@type': 'messageSticker',
          'sticker': {
            '@type': 'sticker',
            'width': 512,
            'height': 512,
            'sticker': _completeFile(11, stickerFile.path),
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(11, 405)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(11, 405)!;
    expect(entry.kindKey, 'historyKindSticker');
    expect(entry.mediaPath, isNotEmpty);
    expect(File(entry.mediaPath).existsSync(), isTrue);
    expect(entry.mediaWidth, 512);
  });
  test('a supergroup follows the groups media switch, not channels', () async {
    final settings = MessageHistorySettings.shared;
    settings.setRecordGroups(true);
    settings.setRecordChannels(false);
    settings.setSnapshotGroups(true);
    settings.setSnapshotChannels(false);
    const supergroupId = -1001234567890;
    await start();
    emitAs(_clientA, 'updateNewChat', {
      'chat': {
        '@type': 'chat',
        'id': supergroupId,
        'type': {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': 1234567890,
          'is_channel': false,
        },
      },
    });
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-supergroup.jpg')
      ..writeAsBytesSync(List.filled(7, 9));
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(supergroupId, 406),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 800,
                'height': 600,
                'photo': _completeFile(21, source.path),
              },
            ],
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(supergroupId, 406)?.mediaPath ?? '').isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final entry = store.entry(supergroupId, 406)!;
    expect(entry.chatId, supergroupId);
    expect(entry.mediaPath, isNotEmpty);
    expect(File(entry.mediaPath).lengthSync(), 7);
  });

  test('an unknown supergroup still honours the groups switch', () async {
    // The type update can be missed (store subscribing after the startup
    // burst); the id alone cannot say supergroup vs channel, so a groups-only
    // setting must keep working instead of silently going dark.
    final settings = MessageHistorySettings.shared;
    settings.setRecordGroups(true);
    settings.setRecordChannels(false);
    settings.setSnapshotGroups(true);
    settings.setSnapshotChannels(false);
    const chatId = -1005554443332;
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-unknown.jpg')
      ..writeAsBytesSync(List.filled(6, 4));
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(chatId, 408),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 640,
                'height': 480,
                'photo': _completeFile(23, source.path),
              },
            ],
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      if ((store.entry(chatId, 408)?.mediaPath ?? '').isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.entry(chatId, 408)!.mediaPath, isNotEmpty);
  });

  test('a channel keeps the channels switch', () async {
    final settings = MessageHistorySettings.shared;
    settings.setRecordGroups(true);
    settings.setRecordChannels(true);
    settings.setSnapshotGroups(true);
    settings.setSnapshotChannels(false);
    const channelId = -1009876543210;
    await start();
    emitAs(_clientA, 'updateNewChat', {
      'chat': {
        '@type': 'chat',
        'id': channelId,
        'type': {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': 9876543210,
          'is_channel': true,
        },
      },
    });
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    final source = File('${dir.path}/tdlib-cache-channel.jpg')
      ..writeAsBytesSync(List.filled(5, 8));
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(channelId, 407),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 800,
                'height': 600,
                'photo': _completeFile(22, source.path),
              },
            ],
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.entry(channelId, 407), isNotNull);
    expect(store.entry(channelId, 407)!.mediaPath, isEmpty);
  });

  test(
    'a copy finishing after removeAccount leaves no snapshot file behind',
    () async {
      final media = MessageMediaSnapshotter.forTesting();
      media.dir = dir;
      store.mediaSnapshotter = media;
      final source = File('${dir.path}/tdlib-cache-voice.oga')
        ..writeAsBytesSync(List.filled(8, 5));
      // Hold every copy right before its post-copy validation, so the
      // account removal lands while the copy is in flight.
      final copyGate = Completer<void>();
      media.beforeValidateForTesting = () => copyGate.future;
      await start();
      emitAs(_clientA, 'updateNewMessage', {
        'message': {
          ..._message(11, 403),
          'content': {
            '@type': 'messageVoiceNote',
            'voice_note': {
              '@type': 'voiceNote',
              'voice': {
                '@type': 'file',
                'id': 8,
                'local': {
                  '@type': 'localFile',
                  'path': source.path,
                  'is_downloading_completed': true,
                  'is_active_downloading': false,
                },
              },
            },
          },
        },
      });
      // Wait until the copy itself has landed on disk (validation still held).
      String? copiedPath;
      for (var i = 0; i < 100; i++) {
        final files = dir
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.contains('${_accountA}_11_'))
            .toList();
        if (files.isNotEmpty) {
          copiedPath = files.single;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(copiedPath, isNotNull, reason: 'the copy never started');

      store.removeAccount(_accountA);
      copyGate.complete();
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.entryCount, 0);
      expect(
        File(copiedPath!).existsSync(),
        isFalse,
        reason: 'an in-flight copy must be deleted, not left behind',
      );
    },
  );
  test('a partially downloaded media file is not snapshotted', () async {
    final media = MessageMediaSnapshotter.forTesting();
    media.dir = dir;
    store.mediaSnapshotter = media;
    await start();
    emitAs(_clientA, 'updateNewMessage', {
      'message': {
        ..._message(11, 401),
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            '@type': 'photo',
            'sizes': [
              {
                '@type': 'photoSize',
                'width': 100,
                'height': 50,
                'photo': {
                  '@type': 'file',
                  'id': 6,
                  'local': {
                    '@type': 'localFile',
                    'path': '/nonexistent/partial.jpg',
                    'is_downloading_completed': false,
                    'is_active_downloading': true,
                  },
                },
              },
            ],
          },
        },
      },
    });
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.entry(11, 401)?.mediaPath, isEmpty);
  });
}
