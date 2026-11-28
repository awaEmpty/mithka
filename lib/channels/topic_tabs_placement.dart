import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the topic tab strip sits for one chat.
///
/// exteraless keeps this per dialog (`topicssidetabs` / `topicssidetabsb` in
/// the main settings) and cycles the tabs through three homes: above the
/// conversation, docked at its left edge, and above the composer. Only a bot
/// topic chat — the reference client's bot forum — offers the control; every
/// other topic chat keeps the default top bar.
enum TopicTabsPlacement { top, side, bottom }

/// The next placement in exteraless's top → side → bottom → top cycle
/// (`TopicsTabsView#onSideMenuButtonClick`).
TopicTabsPlacement nextTopicTabsPlacement(TopicTabsPlacement placement) =>
    switch (placement) {
      TopicTabsPlacement.top => TopicTabsPlacement.side,
      TopicTabsPlacement.side => TopicTabsPlacement.bottom,
      TopicTabsPlacement.bottom => TopicTabsPlacement.top,
    };

/// Persists [TopicTabsPlacement] per account slot and chat.
class TopicTabsPlacementStore {
  TopicTabsPlacementStore._();

  static final TopicTabsPlacementStore shared = TopicTabsPlacementStore._();

  static const _prefix = 'mithka.topicTabsPlacement.v1';

  final Map<String, TopicTabsPlacement> _memory = {};

  String _key(int accountSlot, int chatId) => '$_prefix.$accountSlot.$chatId';

  /// The last known placement, without touching the disk. Defaults to [top].
  TopicTabsPlacement placementFor(int accountSlot, int chatId) =>
      _memory[_key(accountSlot, chatId)] ?? TopicTabsPlacement.top;

  Future<TopicTabsPlacement> load(int accountSlot, int chatId) async {
    final key = _key(accountSlot, chatId);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(key);
    final placement = TopicTabsPlacement.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => TopicTabsPlacement.top,
    );
    _memory[key] = placement;
    return placement;
  }

  Future<void> save(
    int accountSlot,
    int chatId,
    TopicTabsPlacement placement,
  ) async {
    final key = _key(accountSlot, chatId);
    _memory[key] = placement;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, placement.name);
  }

  @visibleForTesting
  void resetForTesting() => _memory.clear();
}
