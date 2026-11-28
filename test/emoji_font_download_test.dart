import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/theme/emoji_channel_source.dart';
import 'package:mithka/theme/emoji_font_catalog.dart';

/// The channel-only catalog round: every pack lives in @mithka_metadata,
/// downloads ride TDLib (never HTTP), cached files verify against the
/// catalog's byte size, and the manifest cache survives a channel outage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory temporary;
  late Directory cacheDir;
  late Map<String, List<int>> channelFonts;
  late _FakeChannelSource source;
  late EmojiFontCatalog catalog;
  late List<String> downloads;

  // A tiny valid-ish font body; only its length matters for verification.
  final appleBytes = List<int>.filled(1024, 7);
  final twemojiBytes = List<int>.filled(512, 3);

  EmojiFontManifestEntry entry(
    String key,
    String label,
    int messageId, {
    int chatId = -100,
    int? previewMessageId,
    int? sizeBytes,
  }) => EmojiFontManifestEntry(
    key: key,
    label: label,
    license: '',
    chatId: chatId,
    channelMessageId: messageId,
    channelPreviewMessageId: previewMessageId,
    sizeBytes: sizeBytes,
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('emoji_font_test');
    messenger.setMockMethodCallHandler(paths, (call) async => temporary.path);
    channelFonts = {'23': appleBytes, '49': twemojiBytes};
    downloads = [];
    source = _FakeChannelSource(channelFonts, downloads);
    catalog = EmojiFontCatalog.forTesting()..debugChannelSource = source;
    cacheDir = Directory(
      '${temporary.path}/${EmojiFontCatalog.cacheDirectoryName}',
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    try {
      await temporary.delete(recursive: true);
    } catch (_) {}
  });

  test('download verifies against the catalog byte size', () async {
    final apple = entry(
      'apple',
      'Apple Color Emoji',
      23,
      sizeBytes: appleBytes.length,
    );
    await catalog.ensureFontDownloaded(apple);
    expect(downloads, ['23']);
    expect(File('${cacheDir.path}/apple.ttf').lengthSync(), 1024);

    // Corrupt the cached file: the size no longer matches, so the next
    // ensure downloads again and restores the original length.
    await File(
      '${cacheDir.path}/apple.ttf',
    ).writeAsBytes(List.filled(16, 1), flush: true);
    await catalog.ensureFontDownloaded(apple);
    expect(downloads, ['23', '23']);
    expect(File('${cacheDir.path}/apple.ttf').lengthSync(), 1024);
  });

  test(
    'a catalog row without a byte size falls back to the size index',
    () async {
      final twemoji = entry('twemoji', 'Twemoji', 49);
      await catalog.ensureFontDownloaded(twemoji);
      final file = File('${cacheDir.path}/twemoji.ttf');
      expect(file.lengthSync(), 512);

      await file.writeAsBytes(List.filled(8, 3), flush: true);
      await catalog.ensureFontDownloaded(twemoji);
      expect(downloads, ['49', '49']);
      expect(file.lengthSync(), 512);
    },
  );

  test(
    'an archived pack downloads the zip and keeps the font inside',
    () async {
      // The channel serves heavy packs as a zip holding `font.ttf` (Apple is a
      // 24 MB archive instead of a 45 MB font document). The catalog follows
      // the archive, extracts the member and verifies THAT length.
      final inner = List<int>.filled(777, 9);
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('preview.png', 4, [1, 2, 3, 4]))
          ..addFile(ArchiveFile('font.ttf', inner.length, inner)),
      );
      channelFonts['60'] = zip;
      final archived = EmojiFontManifestEntry(
        key: 'apple',
        label: 'Apple Color Emoji',
        license: '',
        chatId: -100,
        channelMessageId: 23,
        channelArchiveMessageId: 60,
        sizeBytes: inner.length,
      );

      await catalog.ensureFontDownloaded(archived);
      expect(downloads, [
        '60',
      ], reason: 'the archive wins over the font message');
      final font = File('${cacheDir.path}/apple.ttf');
      expect(font.lengthSync(), inner.length);
      expect(font.readAsBytesSync(), inner);
      expect(File('${cacheDir.path}/apple.ttf.zip').existsSync(), isFalse);

      // A second ensure sees the verified font and downloads nothing.
      await catalog.ensureFontDownloaded(archived);
      expect(downloads, ['60']);
    },
  );

  test('an entry without a usable message id never reaches TDLib', () async {
    final broken = entry('broken', 'Broken', 0);
    expect(broken.isChannelServed, isFalse);
    await expectLater(
      catalog.ensureFontDownloaded(broken),
      throwsA(isA<FileSystemException>()),
    );
    expect(downloads, isEmpty);
  });

  test('loadManifest falls back to the cached catalog when offline', () async {
    // First pass: the channel answers and the manifest cache is written.
    final online = await catalog.loadManifest(forceRefresh: true);
    expect(online, hasLength(2));
    expect(online.map((e) => e.key), containsAll(['apple', 'twemoji']));

    // Go offline: the cache still serves the catalog.
    source.online = false;
    final cached = await catalog.loadManifest();
    expect(cached, hasLength(2));
    expect(cached.map((e) => e.key), containsAll(['apple', 'twemoji']));

    // A cold offline start (no cache) answers with an empty catalog: the
    // picker still draws its system-default row instead of a load failure.
    await File('${cacheDir.path}/manifest.json').delete();
    expect(await catalog.loadManifest(), isEmpty);
  });

  test('fluent rows are dropped from any catalog', () async {
    final manifest = await catalog.loadManifest(forceRefresh: true);
    expect(manifest.map((e) => e.key), isNot(contains('fluent')));
  });

  test(
    'deleteCachedFont removes the file and reports size correctly',
    () async {
      final apple = entry(
        'apple',
        'Apple Color Emoji',
        23,
        sizeBytes: appleBytes.length,
      );

      expect(await catalog.cachedFontSize('apple'), isNull);
      await catalog.ensureFontDownloaded(apple);
      expect(await catalog.cachedFontSize('apple'), 1024);

      expect(await catalog.deleteCachedFont('apple'), isTrue);
      expect(await catalog.cachedFontSize('apple'), isNull);
      expect(File('${cacheDir.path}/apple.ttf').existsSync(), isFalse);
      // Second delete is a safe no-op.
      expect(await catalog.deleteCachedFont('apple'), isFalse);
      // System is never deletable.
      expect(await catalog.deleteCachedFont('system'), isFalse);
    },
  );
}

/// Scripted channel source: serves a fixed catalog and font documents from
/// an in-memory map, recording every font download by message id.
class _FakeChannelSource implements EmojiChannelSource {
  _FakeChannelSource(this.fonts, this.downloads);

  final Map<String, List<int>> fonts;
  final List<String> downloads;
  bool online = true;

  @override
  Future<List<EmojiFontManifestEntry>?> fetchCatalog() async {
    if (!online) return null;
    return [
      EmojiFontManifestEntry(
        key: 'apple',
        label: 'Apple Color Emoji',
        license: '',
        chatId: -100,
        channelMessageId: 23,
        channelPreviewMessageId: 22,
        sizeBytes: fonts['23']?.length,
      ),
      EmojiFontManifestEntry(
        key: 'twemoji',
        label: 'Twemoji',
        license: 'CC-BY-4.0',
        chatId: -100,
        channelMessageId: 49,
        channelPreviewMessageId: 48,
        sizeBytes: fonts['49']?.length,
      ),
    ];
  }

  @override
  Future<int?> downloadFont({
    required int chatId,
    required int messageId,
    required String destPath,
    void Function(double progress)? onProgress,
  }) async {
    final bytes = fonts['$messageId'];
    if (bytes == null) return null;
    downloads.add('$messageId');
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  @override
  Future<int?> downloadArchive({
    required int chatId,
    required int messageId,
    required String destPath,
    void Function(double progress)? onProgress,
  }) async {
    final bytes = fonts['$messageId'];
    if (bytes == null) return null;
    downloads.add('$messageId');
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    onProgress?.call(1);
    return bytes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
