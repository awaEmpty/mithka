//
//  local_database_reset_test.dart
//
//  “重置数据库” wipes the local history and caches (TDLib media, emoji pack
//  binaries and page tiles, the kept-message mirror, drafts, saved downloads,
//  search history) and touches nothing that makes the install the user's: no
//  preference write, no session close.
//

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/search_history_store.dart';
import 'package:mithka/history/message_history_store.dart';
import 'package:mithka/settings/downloads_storage/data_storage_service.dart';
import 'package:mithka/settings/downloads_storage/local_database_reset.dart';
import 'package:mithka/settings/downloads_storage/retained_download_store.dart';
import 'package:mithka/theme/emoji_font_catalog.dart';

class _FakeStorage extends DataStorageService {
  _FakeStorage();

  final calls = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> optimize({
    required int size,
    required int ttl,
    List<Map<String, dynamic>> fileTypes = const [],
    List<int> chatIds = const [],
    List<int> excludeChatIds = const [],
    bool returnDeletedStatistics = false,
    int count = 1000000000,
    int immunityDelay = 3600,
    int chatLimit = 100,
  }) async {
    calls.add({
      'size': size,
      'ttl': ttl,
      'immunityDelay': immunityDelay,
      'types': fileTypes.length,
    });
    return {'@type': 'ok'};
  }
}

class _FakeEmoji extends EmojiFontCatalog {
  _FakeEmoji() : super.forTesting();

  int clears = 0;

  @override
  Future<int> clearCache() async {
    clears += 1;
    return 3;
  }
}

class _FakeSearchHistory extends SearchHistoryStore {
  int clears = 0;

  @override
  Future<void> clearAll() async {
    clears += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the reset evicts caches and never reaches the session', () async {
    final storage = _FakeStorage();
    final emoji = _FakeEmoji();
    final search = _FakeSearchHistory();
    final history = MessageHistoryStore.forTesting();
    final root = await Directory.systemTemp.createTemp('reset-downloads');
    addTearDown(() => root.delete(recursive: true));
    final downloads = RetainedDownloadStore(root);

    await LocalDatabaseReset.run(
      storage: storage,
      emoji: emoji,
      searchHistory: search,
      history: history,
      downloads: downloads,
    );

    expect(storage.calls, hasLength(1));
    expect(storage.calls.single['size'], 0);
    expect(storage.calls.single['ttl'], 0);
    expect(
      storage.calls.single['types'],
      0,
      reason: 'an empty file-type list asks TDLib to evict every cached type',
    );
    expect(emoji.clears, 1);
    expect(search.clears, 1);
    expect(history.entries, isEmpty);
  });

  test('saved downloads are deleted with their metadata', () async {
    final root = await Directory.systemTemp.createTemp('reset-saved');
    addTearDown(() => root.delete(recursive: true));
    final store = RetainedDownloadStore(root);
    final id = 'a' * 64;
    final folder = Directory('${root.path}/$id')..createSync(recursive: true);
    File('${folder.path}/video.mp4').writeAsBytesSync([1, 2, 3]);
    File('${folder.path}/entry.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'file_name': 'video.mp4',
        'size': 3,
        'saved_at': DateTime.now().toIso8601String(),
        'title': 'clip',
        'is_video': true,
      }),
    );
    expect(await store.list(), hasLength(1));

    await LocalDatabaseReset.run(
      storage: _FakeStorage(),
      emoji: _FakeEmoji(),
      searchHistory: _FakeSearchHistory(),
      history: MessageHistoryStore.forTesting(),
      downloads: store,
    );

    expect(await store.list(), isEmpty);
    expect(File('${folder.path}/video.mp4').existsSync(), isFalse);
  });

  test('the copy names what survives', () {
    expect(LocalDatabaseReset.keepsLabel, contains('session'));
    expect(LocalDatabaseReset.keepsLabel, contains('settings'));
  });
}
