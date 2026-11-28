//
//  group_scheduled_deletion.dart
//
//  Client-side fallback for Telegram's per-chat Auto-Delete. Telegram only
//  deletes messages on the server when the chat itself carries a
//  `message_auto_delete_time`; a group without one keeps everything forever.
//  This scheduler removes the messages this account sends in exactly those
//  groups, after a delay chosen in Settings › Privacy & Security.
//
//  Only real group messages are tracked: private chats, channels, Bot API
//  accounts and groups that already carry a server timer are skipped, because
//  Telegram deletes those itself. The queue lives in SharedPreferences keyed
//  by account slot and chat, so a restart still deletes whatever became due
//  while the app was gone.
//

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';

/// The slice of [TdClient] the scheduler uses.
///
/// Production binds to the app's singleton; tests inject a fake so the queue,
/// retries and timer can be exercised without tdjson.
abstract interface class ScheduledDeletionTransport {
  /// Updates of [type] from every configured account, in arrival order.
  Stream<Map<String, dynamic>> updates(String type);

  /// Sends [request] to the client that owns [slot].
  Future<Map<String, dynamic>> query(Map<String, dynamic> request, int slot);

  /// The account slot currently served by [clientId], when registered.
  int? slotForClient(int clientId);

  /// Whether [slot] is a Bot API account (no TDLib message database).
  bool isBotApiSlot(int slot);
}

class _TdClientTransport implements ScheduledDeletionTransport {
  const _TdClientTransport();

  @override
  Stream<Map<String, dynamic>> updates(String type) =>
      TdClient.shared.updatesOf(type, allAccounts: true);

  @override
  Future<Map<String, dynamic>> query(Map<String, dynamic> request, int slot) =>
      TdClient.shared.queryForSlot(request, slot);

  @override
  int? slotForClient(int clientId) => TdClient.shared.slotForClient(clientId);

  @override
  bool isBotApiSlot(int slot) => TdClient.shared.isBotApiSlot(slot);
}

/// One message waiting for its deletion deadline.
@immutable
class ScheduledDeletionEntry {
  const ScheduledDeletionEntry(this.messageId, this.dueMillis, this.attempts);

  final int messageId;

  /// Wall-clock epoch milliseconds at which the message should be deleted.
  final int dueMillis;

  /// Failed deletion attempts so far; drives the retry backoff.
  final int attempts;

  ScheduledDeletionEntry retryAfter(int dueMillis) =>
      ScheduledDeletionEntry(messageId, dueMillis, attempts + 1);

  List<Object> toJson() => [messageId, dueMillis, attempts];
}

class _ChatQueue {
  _ChatQueue(this.slot, this.chatId);

  final int slot;
  final int chatId;
  final List<ScheduledDeletionEntry> entries = [];

  bool contains(int messageId) =>
      entries.any((entry) => entry.messageId == messageId);
}

/// Settings + deletion queue for messages this account sends in groups that
/// have no server-side auto-delete timer.
class GroupScheduledDeletionController extends ChangeNotifier
    with WidgetsBindingObserver {
  GroupScheduledDeletionController({
    ScheduledDeletionTransport? transport,
    DateTime Function()? clock,
  }) : _transport = transport ?? const _TdClientTransport(),
       _clock = clock ?? DateTime.now;

  /// The app-wide controller. Its settings survive restarts in
  /// SharedPreferences; tests build their own instance with a fake transport.
  static final GroupScheduledDeletionController shared =
      GroupScheduledDeletionController();

  static const String enabledPreferenceKey =
      'mithkax.groupScheduledDeletion.enabled.v1';
  static const String durationPreferenceKey =
      'mithkax.groupScheduledDeletion.durationSeconds.v1';
  static const String pendingPreferencePrefix =
      'mithkax.groupScheduledDeletion.pending.v1.';

  static const int defaultDurationSeconds = 86400;
  static const List<int> durationOptionsSeconds = [
    3600,
    86400,
    259200,
    604800,
    2592000,
  ];

  /// MTProto deletes at most 100 ids per request; TDLib does not split them.
  static const int _maxMessagesPerRequest = 100;

  /// Retry delays after a transient failure, capped at one hour.
  static const List<int> _retryDelaysSeconds = [
    30,
    60,
    120,
    300,
    600,
    1800,
    3600,
  ];

  final ScheduledDeletionTransport _transport;
  final DateTime Function() _clock;

  final Map<String, _ChatQueue> _queues = {};
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  SharedPreferences? _prefs;
  Timer? _timer;
  bool _enabled = false;
  int _durationSeconds = defaultDurationSeconds;
  bool _flushing = false;
  bool _listening = false;
  bool _observing = false;

  bool get enabled => _enabled;
  int get durationSeconds => _durationSeconds;
  int get pendingMessageCount =>
      _queues.values.fold(0, (sum, queue) => sum + queue.entries.length);

  static String durationLabelKey(int seconds) {
    switch (seconds) {
      case 3600:
        return AppStringKeys.mithkaxScheduledDeleteOneHour;
      case 86400:
        return AppStringKeys.mithkaxScheduledDeleteOneDay;
      case 259200:
        return AppStringKeys.mithkaxScheduledDeleteThreeDays;
      case 604800:
        return AppStringKeys.mithkaxScheduledDeleteOneWeek;
      case 2592000:
        return AppStringKeys.mithkaxScheduledDeleteOneMonth;
      default:
        return AppStringKeys.mithkaxScheduledDeleteOneDay;
    }
  }

  /// Reads the persisted settings and, when [startScheduler] is true, all
  /// pending deletions and starts the update listeners + timer.
  ///
  /// A secondary desktop engine that only hosts settings passes
  /// `startScheduler: false`: it must not run a second deletion queue against
  /// the same chats.
  void initialize(SharedPreferences prefs, {bool startScheduler = true}) {
    _prefs = prefs;
    _enabled = prefs.getBool(enabledPreferenceKey) ?? false;
    final stored =
        prefs.getInt(durationPreferenceKey) ?? defaultDurationSeconds;
    _durationSeconds = durationOptionsSeconds.contains(stored)
        ? stored
        : defaultDurationSeconds;
    if (!startScheduler) {
      notifyListeners();
      return;
    }
    _reloadQueues();
    _startListening();
    _startObserving();
    if (!_enabled) _clearAllQueues();
    _armTimer();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      _armTimer();
    } else {
      _clearAllQueues();
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
    await _prefs?.setBool(enabledPreferenceKey, value);
  }

  Future<void> setDurationSeconds(int seconds) async {
    if (!durationOptionsSeconds.contains(seconds)) return;
    if (_durationSeconds == seconds) return;
    _durationSeconds = seconds;
    notifyListeners();
    await _prefs?.setInt(durationPreferenceKey, seconds);
  }

  /// Deletes every queued message whose deadline has passed. Public because
  /// the app lifecycle observer and tests both trigger it directly.
  Future<void> flushDue() async {
    if (!_enabled || _flushing) return;
    final now = _clock().millisecondsSinceEpoch;
    final due = <_ChatQueue, List<ScheduledDeletionEntry>>{};
    for (final queue in _queues.values) {
      final entries = [
        for (final entry in queue.entries)
          if (entry.dueMillis <= now) entry,
      ];
      if (entries.isNotEmpty) due[queue] = entries;
    }
    if (due.isEmpty) {
      _armTimer();
      return;
    }
    _flushing = true;
    try {
      for (final batch in due.entries) {
        await _flushQueue(batch.key, batch.value, now);
      }
    } finally {
      _flushing = false;
      _armTimer();
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers do not run while Android suspends the process; catch up as soon
    // as the app is visible again.
    if (state == AppLifecycleState.resumed) unawaited(flushDue());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }

  @visibleForTesting
  List<int> msgIdsForTesting(int slot, int chatId) {
    final queue = _queues[_queueKey(slot, chatId)];
    if (queue == null) return const [];
    return [for (final entry in queue.entries) entry.messageId];
  }

  @visibleForTesting
  void resetForTesting() {
    _enabled = false;
    _durationSeconds = defaultDurationSeconds;
    _prefs = null;
    _queues.clear();
    _timer?.cancel();
    _timer = null;
    _flushing = false;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _listening = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _subscriptions.add(
      _transport.updates('updateNewMessage').listen(_handleNewMessage),
    );
    _subscriptions.add(
      _transport
          .updates('updateMessageSendSucceeded')
          .listen(_handleMessageSent),
    );
    _subscriptions.add(
      _transport
          .updates('updateChatMessageAutoDeleteTime')
          .listen(_handleChatTimerChanged),
    );
    _subscriptions.add(
      _transport.updates('updateAuthorizationState').listen(_handleAuthState),
    );
  }

  void _startObserving() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void _handleNewMessage(Map<String, dynamic> update) {
    _considerMessage(update.obj('message'), update);
  }

  void _handleMessageSent(Map<String, dynamic> update) {
    _considerMessage(update.obj('message'), update);
  }

  void _considerMessage(
    Map<String, dynamic>? message,
    Map<String, dynamic> update,
  ) {
    if (!_enabled || message == null) return;
    if (message.boolean('is_outgoing') != true) return;
    // A locally sent message only becomes real in updateMessageSendSucceeded;
    // its temporary id must never enter the queue.
    if (message.obj('sending_state') != null) return;
    final content = message.obj('content');
    if (TDParse.isServiceContent(content?.type)) return;
    final messageId = message.int64('id');
    final chatId = message.int64('chat_id');
    if (messageId == null || messageId <= 0 || chatId == null) return;
    final slot = _slotOf(update);
    if (slot == null || _transport.isBotApiSlot(slot)) return;
    final existing = _queues[_queueKey(slot, chatId)];
    if (existing != null && existing.contains(messageId)) return;
    final sentAt = message.integer('date') ?? 0;
    unawaited(_schedule(slot, chatId, messageId, sentAt));
  }

  /// Confirms the chat is a plain group without a server timer before adding
  /// the message to the queue.
  Future<void> _schedule(
    int slot,
    int chatId,
    int messageId,
    int sentAtSeconds,
  ) async {
    Map<String, dynamic> chat;
    try {
      chat = await _transport.query({
        '@type': 'getChat',
        'chat_id': chatId,
      }, slot);
    } catch (error) {
      debugPrint('Scheduled deletion: cannot read chat $chatId: $error');
      return;
    }
    if (!_enabled) return;
    // Channels, private chats and secret chats are out of scope. A group with
    // its own auto-delete timer is Telegram's job, not ours.
    if (TDParse.chatKind(chat) != ChatKind.group) return;
    if (_chatAutoDeleteSeconds(chat) > 0) return;

    final now = _clock().millisecondsSinceEpoch;
    final sentAtMillis = sentAtSeconds > 0 ? sentAtSeconds * 1000 : now;
    final due = sentAtMillis + _durationSeconds * 1000;
    // A message that is already older than the chosen window (synced from
    // another device, or the duration was shortened) is due immediately.
    if (!_add(slot, chatId, messageId, due > now ? due : now)) return;
    _armTimer();
  }

  void _handleChatTimerChanged(Map<String, dynamic> update) {
    final chatId = update.int64('chat_id');
    final slot = _slotOf(update);
    if (chatId == null || slot == null) return;
    final seconds =
        update.obj('message_auto_delete_time')?.integer('time') ??
        update.integer('message_auto_delete_time') ??
        update.integer('time') ??
        0;
    // The group just took over deletion for everyone: drop our private plan
    // so a local timer cannot delete messages earlier than the server would.
    if (seconds > 0) _removeChat(slot, chatId);
  }

  void _handleAuthState(Map<String, dynamic> update) {
    final state = update.obj('authorization_state')?.type;
    if (state == 'authorizationStateReady') {
      // TDLib can now serve getChat/deleteMessages; an overdue queue from a
      // previous launch should not wait for the retry backoff.
      unawaited(flushDue());
      return;
    }
    if (state != 'authorizationStateClosed') return;
    final slot = _slotOf(update);
    if (slot == null) return;
    _removeSlot(slot);
  }

  int? _slotOf(Map<String, dynamic> update) {
    final clientId = update.integer('@client_id');
    if (clientId == null) return null;
    return _transport.slotForClient(clientId);
  }

  Future<void> _flushQueue(
    _ChatQueue queue,
    List<ScheduledDeletionEntry> entries,
    int now,
  ) async {
    // Re-read the chat: it may have gained a server timer, been left, or
    // stopped being a group since the message was queued.
    try {
      final chat = await _transport.query({
        '@type': 'getChat',
        'chat_id': queue.chatId,
      }, queue.slot);
      if (TDParse.chatKind(chat) != ChatKind.group ||
          _chatAutoDeleteSeconds(chat) > 0) {
        _removeEntries(queue, entries);
        return;
      }
    } catch (error) {
      if (_isPermanentFailure(error)) {
        debugPrint('Scheduled deletion: dropping chat ${queue.chatId}: $error');
        _removeEntries(queue, entries);
      } else {
        _retryEntries(queue, entries, now);
      }
      return;
    }

    for (
      var start = 0;
      start < entries.length;
      start += _maxMessagesPerRequest
    ) {
      final end = start + _maxMessagesPerRequest < entries.length
          ? start + _maxMessagesPerRequest
          : entries.length;
      final chunk = entries.sublist(start, end);
      try {
        await _transport.query({
          '@type': 'deleteMessages',
          'chat_id': queue.chatId,
          'message_ids': [for (final entry in chunk) entry.messageId],
          'revoke': true,
        }, queue.slot);
        _removeEntries(queue, chunk);
      } catch (error) {
        if (_isPermanentFailure(error)) {
          debugPrint(
            'Scheduled deletion: cannot delete ${chunk.length} message(s) '
            'in chat ${queue.chatId}: $error',
          );
          _removeEntries(queue, chunk);
        } else {
          _retryEntries(queue, chunk, now);
        }
      }
    }
  }

  /// 400/403/404 mean retrying cannot help (chat gone, no permission to
  /// delete for everyone). Everything else — offline, a client that is not
  /// ready yet, a TDLib hiccup — is retried with backoff.
  static bool _isPermanentFailure(Object error) =>
      error is TdError &&
      (error.code == 400 || error.code == 403 || error.code == 404);

  void _retryEntries(
    _ChatQueue queue,
    List<ScheduledDeletionEntry> entries,
    int now,
  ) {
    final attempt = entries
        .map((entry) => entry.attempts)
        .reduce((a, b) => a > b ? a : b);
    final delay =
        _retryDelaysSeconds[attempt.clamp(0, _retryDelaysSeconds.length - 1)];
    final due = now + delay * 1000;
    for (final entry in entries) {
      final index = queue.entries.indexOf(entry);
      if (index < 0) continue;
      queue.entries[index] = entry.retryAfter(due);
    }
    _persist(queue);
  }

  bool _add(int slot, int chatId, int messageId, int dueMillis) {
    final key = _queueKey(slot, chatId);
    final queue = _queues.putIfAbsent(key, () => _ChatQueue(slot, chatId));
    if (queue.contains(messageId)) return false;
    queue.entries.add(ScheduledDeletionEntry(messageId, dueMillis, 0));
    _persist(queue);
    return true;
  }

  void _removeEntries(_ChatQueue queue, List<ScheduledDeletionEntry> entries) {
    final ids = {for (final entry in entries) entry.messageId};
    queue.entries.removeWhere((entry) => ids.contains(entry.messageId));
    if (queue.entries.isEmpty) {
      _queues.remove(_queueKey(queue.slot, queue.chatId));
      final prefs = _prefs;
      if (prefs != null) unawaited(prefs.remove(_preferenceKey(queue)));
    } else {
      _persist(queue);
    }
  }

  void _removeChat(int slot, int chatId) {
    final queue = _queues.remove(_queueKey(slot, chatId));
    if (queue == null) return;
    final prefs = _prefs;
    if (prefs != null) unawaited(prefs.remove(_preferenceKey(queue)));
    _armTimer();
  }

  void _removeSlot(int slot) {
    final keys = [
      for (final key in _queues.keys)
        if (_queues[key]?.slot == slot) key,
    ];
    for (final key in keys) {
      final queue = _queues.remove(key);
      if (queue == null) continue;
      final prefs = _prefs;
      if (prefs != null) unawaited(prefs.remove(_preferenceKey(queue)));
    }
    _armTimer();
  }

  void _clearAllQueues() {
    final prefs = _prefs;
    if (prefs != null) {
      for (final queue in _queues.values) {
        unawaited(prefs.remove(_preferenceKey(queue)));
      }
    }
    _queues.clear();
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || _queues.isEmpty) return;
    int? next;
    for (final queue in _queues.values) {
      for (final entry in queue.entries) {
        if (next == null || entry.dueMillis < next) next = entry.dueMillis;
      }
    }
    if (next == null) return;
    var delay = next - _clock().millisecondsSinceEpoch;
    if (delay < 0) delay = 0;
    _timer = Timer(Duration(milliseconds: delay), () => unawaited(flushDue()));
  }

  void _persist(_ChatQueue queue) {
    final prefs = _prefs;
    if (prefs == null) return;
    if (queue.entries.isEmpty) {
      unawaited(prefs.remove(_preferenceKey(queue)));
      return;
    }
    unawaited(
      prefs.setString(
        _preferenceKey(queue),
        jsonEncode([for (final entry in queue.entries) entry.toJson()]),
      ),
    );
  }

  void _reloadQueues() {
    _queues.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith(pendingPreferencePrefix)) continue;
      final parts = key.substring(pendingPreferencePrefix.length).split('.');
      if (parts.length != 2) continue;
      final slot = int.tryParse(parts[0]);
      final chatId = int.tryParse(parts[1]);
      if (slot == null || chatId == null) continue;
      final entries = _decodeEntries(prefs.getString(key));
      if (entries.isEmpty) {
        unawaited(prefs.remove(key));
        continue;
      }
      _queues[_queueKey(slot, chatId)] = _ChatQueue(slot, chatId)
        ..entries.addAll(entries);
    }
  }

  static List<ScheduledDeletionEntry> _decodeEntries(Object? raw) {
    if (raw is! String) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final entries = <ScheduledDeletionEntry>[];
      for (final item in decoded) {
        if (item is! List || item.length < 2) continue;
        final messageId = jsonInt(item[0]);
        final dueMillis = jsonInt(item[1]);
        final attempts = item.length > 2 ? jsonInt(item[2]) ?? 0 : 0;
        if (messageId == null || messageId <= 0) continue;
        if (dueMillis == null || dueMillis <= 0) continue;
        entries.add(ScheduledDeletionEntry(messageId, dueMillis, attempts));
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  static int _chatAutoDeleteSeconds(Map<String, dynamic> chat) {
    return chat.obj('message_auto_delete_time')?.integer('time') ??
        chat.integer('message_auto_delete_time') ??
        chat.integer('auto_delete_time') ??
        0;
  }

  static String _queueKey(int slot, int chatId) => '$slot:$chatId';

  static String _preferenceKey(_ChatQueue queue) =>
      '$pendingPreferencePrefix${queue.slot}.${queue.chatId}';
}
