//
//  search_history_store.dart
//
//  The chats a search was used to open, newest first — exteraless keeps the
//  same list in its `search_recent` table and shows it as the "Recent" section
//  above an empty search field.
//
//  Entries are chat ids only, keyed by the account's stable Telegram user id:
//  chat ids are account-scoped, so one account's history must never resolve
//  against another account's chats. The order of the list *is* the recency —
//  there is nothing else to sort on — and opening a chat that is already in
//  the list moves it back to the front.
//
//  The store is deliberately small: the view owns the rendering and resolves
//  ids into chat summaries through TDLib, so a history entry never has to be
//  migrated when a chat's title or photo changes.
//

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistoryStore extends ChangeNotifier {
  SearchHistoryStore();

  /// The app-wide store; the mobile search page and the desktop search panel
  /// both record into it.
  static final SearchHistoryStore shared = SearchHistoryStore();

  /// How many searches the list keeps. exteraless stores every row forever;
  /// the visible list is what matters, and 20 keeps the preference small.
  static const int maxEntries = 20;

  static const String _keyPrefix = 'mithka.searchHistory.v1.user';

  SharedPreferences? _prefs;
  final Map<int, List<int>> _cached = {};
  Future<void> _queue = Future<void>.value();

  /// The preference key holding [userId]'s history.
  static String preferenceKey(int userId) => '$_keyPrefix$userId';

  /// The chats [userId] opened from search, newest first.
  ///
  /// Returns an empty list for an unknown account — there is no key to read
  /// and nothing worth writing.
  Future<List<int>> load(int? userId) async {
    if (userId == null) return const [];
    final cached = _cached[userId];
    if (cached != null) return List.unmodifiable(cached);
    final prefs = await _preferences();
    final ids = _decode(prefs.getString(preferenceKey(userId)));
    _cached[userId] = ids;
    return List.unmodifiable(ids);
  }

  /// Moves [chatId] to the front of [userId]'s history.
  Future<void> record(int? userId, int chatId) => _serial(() async {
    if (userId == null || chatId == 0) return;
    final current = await load(userId);
    final next = <int>[chatId, ...current.where((id) => id != chatId)];
    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    await _write(userId, next);
  });

  /// Drops one chat from [userId]'s history.
  Future<void> remove(int? userId, int chatId) => _serial(() async {
    if (userId == null) return;
    final current = await load(userId);
    if (!current.contains(chatId)) return;
    await _write(userId, [
      for (final id in current)
        if (id != chatId) id,
    ]);
  });

  /// Drops the given chats from [userId]'s history.
  ///
  /// The search page clears only the entries it is showing when the query
  /// narrows the list, the way exteraless's filtered "Clear" does.
  Future<void> removeAll(int? userId, Iterable<int> chatIds) =>
      _serial(() async {
        if (userId == null) return;
        final drop = chatIds.toSet();
        if (drop.isEmpty) return;
        final current = await load(userId);
        if (!current.any(drop.contains)) return;
        await _write(userId, [
          for (final id in current)
            if (!drop.contains(id)) id,
        ]);
      });

  /// Forgets every search of [userId].
  /// Wipes every account's recorded searches. The local-database reset uses
  /// this: a search history is cache, not a setting.
  Future<void> clearAll() => _serial(() async {
    final prefs = await _preferences();
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (!key.startsWith(_keyPrefix)) continue;
      await prefs.remove(key);
    }
    _cached.clear();
    notifyListeners();
  });

  Future<void> clear(int? userId) => _serial(() async {
    if (userId == null) return;
    final current = await load(userId);
    if (current.isEmpty) return;
    await _write(userId, const []);
  });

  Future<void> _write(int userId, List<int> ids) async {
    _cached[userId] = List<int>.unmodifiable(ids);
    final prefs = await _preferences();
    await prefs.setString(preferenceKey(userId), jsonEncode(ids));
    notifyListeners();
  }

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Serialises mutations: a record that lands while a clear is still writing
  /// must not resurrect the cleared rows (both read the same cached list).
  ///
  /// The returned future never fails: every caller is a tap handler, and a
  /// preference write that fails must not surface as an unhandled error — the
  /// in-memory list (which the screen reads) is already updated.
  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object _) {});
    return _queue;
  }

  List<int> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final value in decoded)
          if (value is int && value != 0) value,
      ].take(maxEntries).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Drops the in-memory cache so a test starts from its preference state.
  @visibleForTesting
  void resetForTesting() {
    _cached.clear();
    _prefs = null;
    _queue = Future<void>.value();
  }
}
