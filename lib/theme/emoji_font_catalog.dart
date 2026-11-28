//
//  emoji_font_catalog.dart
//
//  Runtime emoji font catalog served entirely from the @mithka_metadata
//  Telegram channel (#emojiv2). Font binaries are channel documents fetched
//  through the active TDLib account, verified against the catalog's byte
//  size, and loaded with Flutter's FontLoader. No external HTTP host is
//  involved — the manifest cache keeps the last catalog for offline starts.
//

import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/json_helpers.dart';
import 'package:path_provider/path_provider.dart';
import 'emoji_channel_source.dart';
import 'platform_font_defaults.dart';

class EmojiFontChoice {
  const EmojiFontChoice({
    required this.key,
    required this.label,
    this.license,
    this.fontFamily,
  });

  static const system = EmojiFontChoice(
    key: 'system',
    label: AppStringKeys.emojiFontCatalogSystemDefault,
  );

  final String key;
  final String label;
  final String? license;
  final String? fontFamily;

  bool get isSystem => key == system.key;

  List<String> get fontFamilies {
    final family = fontFamily;
    if (family == null || family.isEmpty) return platformEmojiFontFallback();
    return _dedupeFontFamilies([family, ...platformEmojiFontFallback()]);
  }

  static List<String> platformEmojiFontFallback() =>
      PlatformFontDefaults.emojiFontFallback();

  static String runtimeFamilyForKey(String key) {
    final sanitized = key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return 'MithkaEmoji_$sanitized';
  }
}

List<String> _dedupeFontFamilies(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
  ];
}

/// One pack in the channel catalog: a font document (and optionally a
/// preview PNG) inside @mithka_metadata, addressed by message id and
/// downloaded through TDLib.
class EmojiFontManifestEntry {
  const EmojiFontManifestEntry({
    required this.key,
    required this.label,
    required this.license,
    required this.chatId,
    required this.channelMessageId,
    this.channelArchiveMessageId,
    this.channelPreviewMessageId,
    this.sizeBytes,
  });

  final String key;
  final String label;
  final String license;

  /// Byte size from the catalog message, used to verify cached files and to
  /// show the download size before the pack is fetched.
  final int? sizeBytes;

  /// @mithka_metadata chat id (0 until the caller stamps the resolved id).
  final int chatId;

  /// Message id of this pack's font document inside the channel. With an
  /// archive this is the fallback font document (older clients) and the
  /// archive wins for this one.
  final int channelMessageId;

  /// Message id of an `application/zip` document carrying this pack's font
  /// (`font.ttf` or the first `.ttf`/`.otf` member). Null for plain-font
  /// packs. The archive is smaller on the wire than the raw font.
  final int? channelArchiveMessageId;

  bool get isArchive => (channelArchiveMessageId ?? 0) > 0;

  /// Message id of this pack's preview PNG inside the channel; null when the
  /// catalog message carries no usable preview id.
  final int? channelPreviewMessageId;

  bool get isChannelServed => channelMessageId > 0;

  String get runtimeFamily => EmojiFontChoice.runtimeFamilyForKey(key);

  /// Channel documents always arrive as .ttf binaries.
  String get extension => 'ttf';
}

class EmojiFontCatalog {
  EmojiFontCatalog._();

  @visibleForTesting
  EmojiFontCatalog.forTesting();

  static final shared = EmojiFontCatalog._();

  /// Bump whenever release font binaries change without changing their keys.
  /// A new namespace prevents old glyph data from being loaded and forces the
  /// selected font to be downloaded again.
  static const cacheRevision = 3;
  static const cacheDirectoryName = 'emoji_fonts_v$cacheRevision';

  /// The catalog source is the @mithka_metadata Telegram channel, reached
  /// through the active TDLib account; the self-hosted HTTP source and its
  /// manifest url were removed with it.

  /// Pluggable channel source; production shares one instance so the
  /// channel chat id resolves once per process. Tests inject a fake.
  @visibleForTesting
  EmojiChannelSource? debugChannelSource;

  final EmojiChannelSource _channelSource = EmojiChannelSource();

  /// Last chat id the channel source resolved, for cache-rehydrated entries
  /// whose serialized chat_id predates a process restart.
  int? _channelLastChatId;

  final Set<String> _loadedFamilies = {};
  final Map<String, Future<String>> _inFlightFontLoads = {};

  /// Returns the deterministic runtime family once this process has registered
  /// it with Flutter. New ThemeController instances can therefore retain the
  /// selected emoji face synchronously instead of flashing the platform face
  /// until another asynchronous cache read completes.
  String? loadedFamilyForKey(String key) {
    if (key == EmojiFontChoice.system.key) return null;
    final family = EmojiFontChoice.runtimeFamilyForKey(key);
    return _loadedFamilies.contains(family) ? family : null;
  }

  Future<List<EmojiFontManifestEntry>> loadManifest({
    bool forceRefresh = false,
  }) async {
    final cacheFile = await _manifestCacheFile();
    if (!forceRefresh && await cacheFile.exists()) {
      final cached = await _readManifest(cacheFile);
      if (cached.isNotEmpty) {
        final cachedChatId = cached.first.chatId;
        if (cachedChatId != 0) {
          _channelLastChatId = cachedChatId;
          return cached;
        }
        // Cached entries predate the chat-id stamp (old build wrote chat_id
        // 0). Falling through re-fetches the catalog so the fresh entries
        // carry the resolved channel id — otherwise every download fails
        // with "channel emoji font unavailable".
        debugPrint(
          '[emoji_font_catalog] cached manifest has no chat id, refreshing',
        );
      }
    }

    final entries = await (debugChannelSource ?? _channelSource).fetchCatalog();
    if (entries == null || entries.isEmpty) {
      // Channel unreachable (no account / offline): serve whatever is cached,
      // or an empty list so the picker still renders the system-default row
      // instead of a hard "load failed" screen.
      if (await cacheFile.exists()) {
        final cached = await _readManifest(cacheFile);
        if (cached.isNotEmpty) return cached;
      }
      debugPrint(
        '[emoji_font_catalog] catalog unavailable, returning empty list',
      );
      return const <EmojiFontManifestEntry>[];
    }
    _channelLastChatId = entries.first.chatId;
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsString(
      jsonEncode({
        'generated': DateTime.now().toIso8601String(),
        'source': 'channel',
        'fonts': [
          for (final e in entries)
            {
              'key': e.key,
              'label': e.label,
              'license': e.license,
              'chat_id': e.chatId,
              'message_id': e.channelMessageId,
              'archive_message_id': e.channelArchiveMessageId,
              'preview_message_id': e.channelPreviewMessageId,
              'bytes': e.sizeBytes,
            },
        ],
      }),
      flush: true,
    );
    return entries;
  }

  Future<String?> loadCached(String key) async {
    if (key == EmojiFontChoice.system.key) return null;
    final file = await _cachedFontFileForKey(key);
    if (file == null) return null;
    final family = EmojiFontChoice.runtimeFamilyForKey(key);
    await _loadFontFile(family, file);
    return family;
  }

  Future<String?> loadCachedOrDownload(String key) async {
    final cached = await loadCached(key);
    if (cached != null) return cached;
    try {
      final entries = await loadManifest(forceRefresh: true);
      EmojiFontManifestEntry? selected;
      for (final entry in entries) {
        if (entry.key == key) {
          selected = entry;
          break;
        }
      }
      if (selected == null) return null;
      return downloadAndLoad(selected);
    } catch (error) {
      debugPrint(
        '[emoji_font_catalog] redownload failed key=$key '
        'type=${error.runtimeType}',
      );
      return null;
    }
  }

  /// Downloads (if needed) and registers an entry.
  Future<String> downloadAndLoad(
    EmojiFontManifestEntry entry, {
    void Function(double progress)? onProgress,
  }) {
    final pending = _inFlightFontLoads[entry.key];
    if (pending != null) return pending;
    final operation = _downloadAndLoad(entry, onProgress: onProgress);
    _inFlightFontLoads[entry.key] = operation;
    return operation.whenComplete(() {
      if (identical(_inFlightFontLoads[entry.key], operation)) {
        _inFlightFontLoads.remove(entry.key);
      }
    });
  }

  Future<String> _downloadAndLoad(
    EmojiFontManifestEntry entry, {
    void Function(double progress)? onProgress,
  }) async {
    await ensureFontDownloaded(entry, onProgress: onProgress);
    await _loadFontFile(entry.runtimeFamily, await _fontFile(entry));
    return entry.runtimeFamily;
  }

  /// Brings the entry's cached file to a verified, complete state: downloads
  /// when missing or size-mismatched (against the catalog's byte size,
  /// falling back to the size recorded at download time).
  Future<void> ensureFontDownloaded(
    EmojiFontManifestEntry entry, {
    void Function(double progress)? onProgress,
  }) async {
    final file = await _fontFile(entry);
    if (await _verifyFontFile(entry, file)) return;
    final bytes = await _downloadFontTo(entry, file, onProgress: onProgress);
    final sizes = await _readSizeIndex();
    sizes[entry.key] = bytes;
    await _writeSizeIndex(sizes);
  }

  /// Removes every downloaded pack from this revision's cache. The picker
  /// selection and the catalog manifest stay: the next launch re-downloads
  /// the chosen pack, and the manifest keeps working offline.
  Future<int> clearCache() async {
    var removed = 0;
    final dir = await _cacheDir();
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == _sizeIndexFileName || name == 'manifest.json') continue;
      try {
        await entity.delete();
        removed += 1;
      } catch (_) {
        // A locked file survives; the next download overwrites it.
      }
    }
    return removed;
  }

  /// Deletes a pack's cached font file (the picker's swipe-to-delete). Safe
  /// for any key: missing files are a no-op, the running family registration
  /// is only in-memory and dies with the process. Returns whether a file was
  /// removed.
  Future<bool> deleteCachedFont(String key) async {
    if (key == EmojiFontChoice.system.key) return false;
    final file = await _cachedFontFileForKey(key);
    if (file == null) return false;
    try {
      await file.delete();
    } catch (_) {
      return false;
    }
    final sizes = await _readSizeIndex();
    if (sizes.containsKey(key)) {
      sizes.remove(key);
      await _writeSizeIndex(sizes);
    }
    return true;
  }

  /// On-disk size of a cached pack, or null when it is not downloaded.
  Future<int?> cachedFontSize(String key) async {
    if (key == EmojiFontChoice.system.key) return null;
    final file = await _cachedFontFileForKey(key);
    if (file == null) return null;
    try {
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  Future<List<EmojiFontManifestEntry>> _readManifest(File file) async {
    return _parseManifest(await file.readAsString());
  }

  List<EmojiFontManifestEntry> _parseManifest(String body) {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    // The cached channel catalog: entries carry the channel message ids.
    final fonts = decoded['fonts'] as List? ?? const [];
    return [
          for (final item in fonts)
            if (item is Map) _tryParseChannelEntry(item),
        ]
        .whereType<EmojiFontManifestEntry>()
        // The Fluent pack is deliberately absent (its release binary is
        // mis-built and the user removed the set): drop any catalog's
        // fluent rows, any spelling, instead of shipping broken rows.
        .where((entry) => entry.key != 'fluent')
        .toList()
      ..retainAfterFirstByKey();
  }

  EmojiFontManifestEntry? _tryParseChannelEntry(Map<dynamic, dynamic> json) {
    final key = (json['key'] as String?)?.trim() ?? '';
    final label = (json['label'] as String?)?.trim() ?? '';
    final chatId = jsonInt(json['chat_id']);
    final messageId = jsonInt(json['message_id']);
    final archiveMessageId = jsonInt(json['archive_message_id']);
    final previewMessageId = jsonInt(json['preview_message_id']);
    if (key.isEmpty || label.isEmpty || messageId == null || messageId <= 0) {
      return null;
    }
    return EmojiFontManifestEntry(
      key: key,
      label: label,
      license: (json['license'] as String?)?.trim() ?? '',
      chatId: chatId ?? 0,
      channelMessageId: messageId,
      channelArchiveMessageId:
          (archiveMessageId != null && archiveMessageId > 0)
          ? archiveMessageId
          : null,
      channelPreviewMessageId:
          (previewMessageId != null && previewMessageId > 0)
          ? previewMessageId
          : null,
      sizeBytes: jsonInt(json['bytes']),
    );
  }

  /// Test seam: run the same parse the manifest loader uses.
  @visibleForTesting
  List<EmojiFontManifestEntry> parseManifestForTesting(String body) =>
      _parseManifest(body);

  /// Cached font bytes are loaded straight into the engine — a truncated
  /// file would register as a broken family or crash the loader, so every
  /// write goes through a temp file + atomic rename and every read verifies
  /// the recorded size (the catalog's byte size wins when present).
  static const _sizeIndexFileName = 'sizes.json';

  Future<File> _sizeIndexFile() async {
    final dir = await _cacheDir();
    return File('${dir.path}/$_sizeIndexFileName');
  }

  Future<Map<String, int>> _readSizeIndex() async {
    try {
      final file = await _sizeIndexFile();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  Future<File> _writeSizeIndex(Map<String, int> sizes) async {
    final file = await _sizeIndexFile();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(sizes), flush: true);
    if (await file.exists()) await file.delete();
    return tmp.rename(file.path);
  }

  Future<int> _downloadFontTo(
    EmojiFontManifestEntry entry,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    var chatId = entry.chatId != 0 ? entry.chatId : _channelLastChatId;
    if ((chatId == null || chatId == 0) && entry.isChannelServed) {
      // Cached entries may predate the chat-id stamp — resolve the channel
      // id by re-fetching the catalog instead of failing every download.
      final refreshed = await (debugChannelSource ?? _channelSource)
          .fetchCatalog();
      if (refreshed != null && refreshed.isNotEmpty) {
        _channelLastChatId = refreshed.first.chatId;
        chatId = refreshed.first.chatId;
        debugPrint(
          '[emoji_font_catalog] resolved chat id from refresh: $chatId',
        );
      }
    }
    if (chatId == null || chatId == 0 || !entry.isChannelServed) {
      debugPrint(
        '[emoji_font_catalog] channel unavailable key=${entry.key} '
        'chatId=$chatId entryChatId=${entry.chatId} '
        'lastChatId=$_channelLastChatId msgId=${entry.channelMessageId}',
      );
      throw const FileSystemException('channel emoji font unavailable');
    }
    // An archived pack downloads its zip first, then the font comes out of
    // the archive: the channel ships the Apple set as a 24 MB zip instead of
    // a 45 MB font document.
    final archiveMessageId = entry.channelArchiveMessageId;
    if (archiveMessageId != null && archiveMessageId > 0) {
      final archiveBytes = await (debugChannelSource ?? _channelSource)
          .downloadArchive(
            chatId: chatId,
            messageId: archiveMessageId,
            destPath: '${file.path}.zip',
            // The download owns the first 90% of the progress line; the
            // extract is instant next to it.
            onProgress: onProgress == null
                ? null
                : (progress) => onProgress(progress * 0.9),
          );
      if (archiveBytes == null || archiveBytes <= 0) {
        throw const FileSystemException('channel emoji font unavailable');
      }
      final font = await _extractFontFromArchive(File('${file.path}.zip'));
      if (font == null) {
        debugPrint('[emoji_font_catalog] archive has no font key=${entry.key}');
        throw const FileSystemException('emoji archive has no font');
      }
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(font, flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      onProgress?.call(1);
      return font.length;
    }
    final bytes = await (debugChannelSource ?? _channelSource).downloadFont(
      chatId: chatId,
      messageId: entry.channelMessageId,
      destPath: '${file.path}.tmp',
      onProgress: onProgress,
    );
    if (bytes == null || bytes <= 0) {
      throw const FileSystemException('channel emoji font unavailable');
    }
    if (await file.exists()) await file.delete();
    await File('${file.path}.tmp').rename(file.path);
    return bytes;
  }

  /// Reads the pack's font out of a downloaded archive and deletes the zip.
  ///
  /// `font.ttf` wins when the archive names it (the reference channel's
  /// layout); otherwise the first `.ttf`/`.otf` member is used. A zip of
  /// preview images (the channel also carries image-only packs) yields null,
  /// so the caller fails the pack instead of registering a broken family.
  Future<Uint8List?> _extractFontFromArchive(File archive) async {
    try {
      final bytes = await archive.readAsBytes();
      final decoded = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? chosen;
      for (final file in decoded.files) {
        if (!file.isFile) continue;
        final name = file.name.toLowerCase();
        if (!name.endsWith('.ttf') && !name.endsWith('.otf')) continue;
        if (name.split('/').last == 'font.ttf') {
          chosen = file;
          break;
        }
        chosen ??= file;
      }
      if (chosen == null) return null;
      final content = chosen.content;
      return content.isEmpty ? null : content;
    } catch (error) {
      debugPrint(
        '[emoji_font_catalog] archive extract failed '
        'type=${error.runtimeType}',
      );
      return null;
    } finally {
      try {
        await archive.delete();
      } catch (_) {
        // A leftover zip is retried by the next download; never fatal.
      }
    }
  }

  Future<File> _manifestCacheFile() async {
    final dir = await _cacheDir();
    return File('${dir.path}/manifest.json');
  }

  Future<File> _fontFile(EmojiFontManifestEntry entry) async {
    final dir = await _cacheDir();
    return File('${dir.path}/${entry.key}.${entry.extension}');
  }

  /// Returns a cached channel preview image for [entry], downloading it
  /// from the @mithka_metadata channel on first use. Null when the entry
  /// has no channel preview id or the download fails — callers fall back to
  /// the bundled asset map.
  Future<File?> channelPreviewFile(EmojiFontManifestEntry entry) async {
    final previewMessageId = entry.channelPreviewMessageId;
    if (previewMessageId == null || previewMessageId <= 0) return null;
    var chatId = entry.chatId != 0 ? entry.chatId : _channelLastChatId;
    if (chatId == null || chatId == 0) {
      // Same cache-predates-chat-id case as _downloadFontTo: resolve the
      // channel id before giving up, otherwise every preview falls back.
      final refreshed = await (debugChannelSource ?? _channelSource)
          .fetchCatalog();
      if (refreshed == null || refreshed.isEmpty) return null;
      _channelLastChatId = refreshed.first.chatId;
      chatId = refreshed.first.chatId;
      if (chatId == 0) return null;
      debugPrint(
        '[emoji_font_catalog] resolved preview chat id from refresh: $chatId',
      );
    }
    final dir = await _cacheDir();
    final file = File('${dir.path}/preview_${entry.key}.png');
    if (await file.exists()) {
      if (await file.length() > 0) return file;
      return null;
    }
    final bytes = await (debugChannelSource ?? _channelSource).downloadPreview(
      chatId: chatId,
      messageId: previewMessageId,
      destPath: file.path,
    );
    return (bytes != null && bytes > 0) ? file : null;
  }

  Future<File?> _cachedFontFileForKey(String key) async {
    final dir = await _cacheDir();
    if (!await dir.exists()) return null;
    await for (final entity in dir.list()) {
      if (entity is File && entity.uri.pathSegments.last.startsWith('$key.')) {
        return entity;
      }
    }
    return null;
  }

  /// The downloaded font files live under the app-support directory in this
  /// revision-tagged cache folder. Every pack is downloaded on demand — none
  /// ships in the APK.
  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$cacheDirectoryName');
  }

  /// FontLoader.load() blocks forever on the widget-test engine (the
  /// platform channel never answers). Tests set this to register the family
  /// without the engine call.
  @visibleForTesting
  static bool debugSkipEngineFontLoad = false;

  Future<void> _loadFontFile(String family, File file) async {
    if (_loadedFamilies.contains(family)) return;
    final bytes = await file.readAsBytes();
    if (!debugSkipEngineFontLoad) {
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
    _loadedFamilies.add(family);
  }

  /// A font file is valid when its size matches the byte size recorded at
  /// download time (the same size the catalog message carries). Files with
  /// no recorded expectation (a size index that predates the download) are
  /// trusted by existence alone. The catalog's own byte size wins when both
  /// are present — the canonical source of truth.
  Future<bool> _verifyFontFile(EmojiFontManifestEntry entry, File file) async {
    if (!await file.exists()) return false;
    final catalogSize = entry.sizeBytes;
    if (catalogSize != null && catalogSize > 0) {
      try {
        return await file.length() == catalogSize;
      } catch (_) {
        return false;
      }
    }
    final sizes = await _readSizeIndex();
    final recorded = sizes[entry.key];
    if (recorded == null) return true;
    return await file.length() == recorded;
  }
}

extension _EmojiFontEntryDedupe on List<EmojiFontManifestEntry> {
  /// Keep the first entry per key.
  void retainAfterFirstByKey() {
    final seen = <String>{};
    removeWhere((entry) => !seen.add(entry.key));
  }
}
