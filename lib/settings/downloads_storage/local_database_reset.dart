//
//  local_database_reset.dart
//
//  “重置数据库”: wipe every local trace of the conversation history while
//  keeping what makes the install *the user's* — the TDLib session (no
//  re-login), every preference and the chosen emoji pack.
//
//  What goes: the kept-message mirror and its media snapshots, TDLib's cached
//  media files, downloaded emoji binaries (fonts and page packs), unsent
//  drafts, saved downloads, the recorded search history and Flutter's
//  in-memory image cache.
//
//  TDLib's own database directory is deliberately NOT touched: the account's
//  authorization key lives inside it, so deleting it would log the user out
//  even though the request is only about a stale cache.
//

import 'package:flutter/painting.dart';

import '../../chats/search_history_store.dart';
import '../../history/message_history_store.dart';
import '../../tdlib/td_client.dart';
import '../../theme/emoji_font_catalog.dart';
import 'data_storage_service.dart';
import 'retained_download_store.dart';

class LocalDatabaseReset {
  LocalDatabaseReset._();

  /// Human-readable description of what survives the wipe, for the confirm
  /// card and the settings subtitle. One place so the copy cannot drift.
  static const keepsLabel = 'settings, session and the chosen emoji pack';

  /// The current account's retained-download store, or null when the slot has
  /// no live client (the reset is also callable from a preview surface).
  static Future<RetainedDownloadStore?> _accountDownloads() async {
    final client = TdClient.shared;
    if (!client.hasActiveClient) return null;
    try {
      return await RetainedDownloadStore.forAccount(client.activeSlot);
    } catch (_) {
      return null;
    }
  }

  static Future<void> run({
    DataStorageService? storage,
    MessageHistoryStore? history,
    EmojiFontCatalog? emoji,
    SearchHistoryStore? searchHistory,
    RetainedDownloadStore? downloads,
  }) async {
    // 1. The kept-message mirror plus every media snapshot it wrote.
    (history ?? MessageHistoryStore.shared).clearAll();

    // 2. TDLib's cached media. `optimizeStorage` with size 0 and an empty
    //    type list asks it to drop every cached file it may evict; the
    //    session, the message database and the chat list are untouched.
    try {
      await (storage ?? const DataStorageService()).optimize(
        size: 0,
        ttl: 0,
        immunityDelay: 0,
        chatLimit: 200,
      );
    } catch (_) {
      // A slot without an active client (signed out, or a preview surface)
      // has nothing to evict; the rest of the reset still stands.
    }

    // 3. Downloaded emoji packs: binaries only, the catalog manifest and the
    //    chosen key stay so the next launch re-fetches what is needed.
    try {
      await (emoji ?? EmojiFontCatalog.shared).clearCache();
    } catch (_) {
      // Cache accounting is best effort.
    }

    // 4. Drafts: TDLib keeps them in its own database next to the message
    //    cache, so they are cleared through the API. The session and the
    //    account stay signed in.
    try {
      if (TdClient.shared.hasActiveClient) {
        await TdClient.shared.query({
          '@type': 'clearAllDraftMessages',
          'exclude_secret_chats': false,
        });
      }
    } catch (_) {
      // A slot without a client has no drafts to clear.
    }

    // 5. Saved downloads: the retained copies the user asked to keep. Each
    //    entry owns a file plus its metadata, and removing one is exactly the
    //    panel's own delete path.
    try {
      final store = downloads ?? await _accountDownloads();
      if (store != null) {
        for (final entry in await store.list()) {
          await store.remove(entry.id).catchError((_) {});
        }
      }
    } catch (_) {
      // A signed-out slot has no store.
    }

    // 6. Search history is a convenience cache, not a preference.
    try {
      await (searchHistory ?? SearchHistoryStore.shared).clearAll();
    } catch (_) {
      // Same.
    }

    // 7. Decoded images held by this process.
    final images = PaintingBinding.instance.imageCache;
    images.clear();
    images.clearLiveImages();
  }
}
