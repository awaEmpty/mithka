//
//  message_history_store.dart
//
//  Kept-message local history: every incoming message is mirrored
//  into a small on-device store so messages the counterpart deletes or edits
//  stay readable afterwards. Nothing here talks to Telegram — the mirror is
//  written from TDLib updates the account already received, and the kept
//  copies never leave this device.
//
//  Every record is owned by the account that received it: TDLib stamps each
//  update with '@client_id', the store resolves that to the account's user id
//  (getMe, cached) and keys entries, pending edit dates and exclusions by it.
//  Two accounts that see the same chat/message ids therefore keep two
//  separate records, and the viewer only ever shows the active account's.
//
//  The whole feature is a Telegram API Terms section 1.4 exception, so every
//  entry point — the TDLib subscription, the persisted file, the preference
//  keys, the settings row and the viewer route — is guarded by the
//  compile-time [allowTelegramTosViolations] constant. With the flag omitted
//  or false, no update is subscribed, no file or preference is read or
//  written, and every method is a no-op, so pre-existing saved state can
//  never take effect either.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/forum_topic_transcript.dart';
import '../chat/media/media_prefetch.dart';
import '../config/build_flags.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import 'message_history_models.dart';
import 'message_history_settings.dart';
import 'message_media_snapshot.dart';

export 'message_history_models.dart';

/// Resolves a TDLib client id to the owning account's user id. Production
/// asks the client itself (getMe) and caches; tests inject the mapping.
abstract class TosAccountUserIdResolver {
  Future<int?> resolve(int clientId);

  /// getMe through the exact client that produced the update. A client that
  /// is gone (slot removed, shutting down) resolves to null, and updates
  /// from it are dropped rather than misattributed.
  static final TosAccountUserIdResolver production = _TdClientUserIdResolver();
}

class _TdClientUserIdResolver implements TosAccountUserIdResolver {
  final Map<int, int> _cache = {};

  @override
  Future<int?> resolve(int clientId) async {
    final cached = _cache[clientId];
    if (cached != null) return cached;
    try {
      final me = await TdClient.shared.queryTo({'@type': 'getMe'}, clientId);
      final userId = me.int64('id');
      if (userId == null) return null;
      _cache[clientId] = userId;
      return userId;
    } catch (_) {
      return null;
    }
  }
}

/// One media file a kept message is waiting on: TDLib reports its completion
/// through updateFile, and the copy taken at that moment is the only one a
/// deleted message will ever get.
class _TrackedMediaFile {
  _TrackedMediaFile({
    required this.width,
    required this.height,
    this.poster = false,
  });

  /// Pixel size of this exact file (a photo's sizes differ per candidate), 0
  /// when the content does not carry one. Used to decide whether a file that
  /// just landed is worth replacing an existing snapshot with.
  int width;
  int height;

  /// True when this file is a poster (thumbnail), not the media file itself.
  bool poster;

  /// Latest TDLib file object seen (arrival payload or updateFile).
  Map<String, dynamic>? file;

  /// Kept copies of this account that reference the file.
  final Set<String> entryKeys = <String>{};
}

/// One file a media content payload can be kept from, with the metadata the
/// viewer and the ghost bubble need to draw it.
class _MediaCandidate {
  const _MediaCandidate({
    required this.file,
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    this.fileName = '',
    this.mimeType = '',
    this.poster = false,
  });

  final Map<String, dynamic> file;
  final int width;
  final int height;
  final int duration;
  final String fileName;
  final String mimeType;

  /// True for a thumbnail that previews a video/animated media. Posters land
  /// in the entry's `mediaPosterPath`, never in `mediaPath`.
  final bool poster;

  int get fileId => file.integer('id') ?? 0;

  int get area => width * height;

  String get localPath => file.obj('local')?.str('path') ?? '';
}

/// Owns the mirrored message history: records TDLib updates, keeps the
/// entries in memory and persists a bounded batch to one JSON file.
class MessageHistoryStore extends ChangeNotifier {
  MessageHistoryStore._();

  static final MessageHistoryStore shared = MessageHistoryStore._();

  @visibleForTesting
  factory MessageHistoryStore.forTesting() = MessageHistoryStore._;

  static const _prefsKeyPrefix = 'messageHistory.excludedChats.v2.';
  static const _fileName = 'message-history.json';
  static const _tmpSuffix = '.tmp';

  /// Bounded on purpose: the mirror is a safety net for recent surprises,
  /// not an archival copy of the account.
  static const maxEntries = 5000;
  static const persistBatch = 400;

  static const observedUpdateTypes = [
    'updateNewMessage',
    'updateMessageEdited',
    'updateMessageContent',
    'updateDeleteMessages',
    // A chat whose counterpart deleted their account (or the chat) stops
    // being openable; kept entries then render in the ghost style.
    'updateChat',
    // Carries the chat's TYPE. TDLib chat ids do not encode whether a
    // supergroup is a channel (-100… covers both), and the per-class record /
    // snapshot switches must know: treating every supergroup as a channel
    // meant a "groups" switch never applied to the groups users actually
    // have.
    'updateNewChat',
    // A kept message's media file often finishes downloading only after the
    // message was recorded (the first paint downloads the size it shows).
    // Completion is the one moment the file can still be copied — once the
    // message is deleted, its file reference is gone.
    'updateFile',
  ];

  final Map<String, MessageHistoryEntry> _byKey = {};

  /// Excluded chats per owning account; the read/write APIs operate on the
  /// active account's set.
  final Map<int, Set<int>> _excludedChatsByAccount = {};

  /// (account, chat) scopes whose chat TDLib reported gone (deleted account /
  /// unresolvable chat). Kept entries of a dead chat render in the ghost
  /// style; not persisted — TDLib re-reports the state on the next sync.
  final Set<String> _deadChats = {};

  /// Pending updateMessageEdited dates, keyed per account. An edit or
  /// deletion observed on one account can never touch another account's
  /// entry even when the chat/message ids are identical.
  final Map<String, int> _pendingEditDates = {};

  /// updateMessageContent payloads that arrived BEFORE their
  /// updateMessageEdited. TDLib's catch-up can deliver the pair in either
  /// order; the content waits here for its date instead of being lost, and
  /// expires unapplied (a content generation — dice, poll, live location —
  /// never gets a date and must not become a revision).
  final Map<String, ({Map<String, dynamic> update, int at})>
  _lateContentUpdates = {};

  /// How long a content payload waits for its edited date. Both halves of
  /// a pair ride the same update batch, so seconds are already generous;
  /// keeping it short bounds a generation landing right before an edit.
  static const _lateContentWindowSeconds = 5;

  /// Cap on waiting payloads; beyond it expired ones are dropped first and
  /// the rest only in a flood (a live location update stream).
  static const _lateContentLimit = 256;

  /// Identity resolution state per TDLib client. While a lookup is in
  /// flight every arrival of that client shares it; a known identity stays
  /// memoized for later events, a failed one is dropped so the next
  /// arrival starts a fresh attempt instead of caching the failure.
  final Map<int, Future<int?>> _identityFutures = {};

  /// Per-CLIENT arrival chains: an update joins its client's chain before
  /// identity resolution, so a client's records apply in TDLib arrival
  /// order no matter how long its getMe takes. Different clients stay
  /// parallel.
  final Map<int, Future<void>> _clientWorkers = {};

  /// Files of kept messages whose download had not finished when the message
  /// was recorded. Keyed by TDLib file id; [updateFile] is what turns one of
  /// these into a snapshot. A media message carries one file per size (a
  /// photo has several), so every candidate is tracked and the largest copy
  /// that lands on disk wins — including an upgrade of an earlier, smaller
  /// snapshot.
  final Map<int, _TrackedMediaFile> _trackedMedia = {};

  /// Reverse index of [_trackedMedia] for scope pruning: entry key → file ids.
  final Map<String, Set<int>> _entryMediaFileIds = {};

  /// Deleted entries that a live transcript has since confirmed to exist.
  /// Batched so a whole history page costs one notification.
  final Set<String> _pendingAliveKeys = {};
  bool _aliveFlushScheduled = false;

  /// Generation of the store's contents. Only the explicitly GLOBAL
  /// operations bump it — [clearAll] and [dispose] — and an async
  /// continuation captures it when its update ARRIVES (or its load starts)
  /// and re-checks before writing, so work queued before one of those can
  /// never resurrect the wiped state. Scoped invalidations (removing one
  /// account, clearing one chat) must not cancel unrelated accounts' and
  /// chats' pending work, so they stamp the scope instead — see
  /// [_scopeEpoch].
  int _generation = 0;

  /// Monotonic epoch of SCOPED invalidations: [removeAccount] and
  /// [clearChat] stamp the scope with its value instead of touching the
  /// global generation, so pending updates, loads and active-account
  /// continuations of every other owner keep running.
  int _scopeEpoch = 0;

  /// Scope epoch at which each account was removed. A queued update that
  /// ARRIVED before its account was removed (`removedAt > arrival`) is
  /// dropped after the identity resolves, so pending work can never
  /// resurrect removed history; later arrivals record again (the slot may
  /// have re-registered), as they always did.
  final Map<int, int> _removedAccountAt = {};

  /// Scope epoch at which each (account, chat) was cleared, keyed
  /// `'$accountUserId:$chatId'`. A queued update for that chat that arrived
  /// before the clear is dropped after the identity resolves — a chat the
  /// user cleared must not be recreated by updates already in flight.
  /// Later arrivals record again. [includeChat] deliberately does not
  /// remove a stamp: re-including an excluded chat is not an un-clear, and
  /// the clear's protection must survive it.
  final Map<String, int> _clearedChatAt = {};

  /// Scope epoch the PERSISTED mirror file last reflected. Loads compare
  /// each disk row's scope stamp against this (not the live epoch): rows of
  /// a scope invalidated after the last persist are stale on disk and are
  /// dropped, while once the writer has rewritten the file the same load
  /// rule lets every surviving row — including later rows of a
  /// re-registered account — apply freely. The stamps are never deleted, so
  /// a queued update resolving long after the invalidation is still
  /// classified correctly.
  int _persistedScopeEpoch = 0;
  int _clearedAllAt = 0;

  /// Resolved user id of the active client, kept in sync with
  /// [TosAccountUserIdResolver] results; null while unresolved.
  int? _activeAccountUserId;
  int? _activeAccountUserIdSource;

  /// Injected per-account id mapping (tests); defaults to getMe per client.
  @visibleForTesting
  TosAccountUserIdResolver? accountUserIdResolver;

  /// The active TDLib client id (tests); defaults to the shared client.
  @visibleForTesting
  int Function()? activeClientIdProvider;

  /// The active-slot change stream (tests); defaults to the shared client.
  @visibleForTesting
  Stream<int> Function()? activeSlotChangeSource;

  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _observing = false;
  StreamSubscription<Map<String, dynamic>>? _tdSub;
  StreamSubscription<int>? _activeSlotSub;
  Timer? _persistTimer;
  bool _persisting = false;
  bool _dirtyWhilePersisting = false;
  bool _disposed = false;

  /// Directory holding the mirror file. Resolved lazily; tests inject one.
  Directory? fileDir;

  /// Holds the file-commit boundary in persistence cancellation tests.
  @visibleForTesting
  Future<void> Function()? beforePersistRenameForTesting;

  TosAccountUserIdResolver get _resolver =>
      accountUserIdResolver ?? TosAccountUserIdResolver.production;

  int? get _currentClientId {
    final provider = activeClientIdProvider;
    if (provider != null) {
      final clientId = provider();
      return clientId == 0 ? null : clientId;
    }
    final clientId = TdClient.shared.activeClientId;
    return clientId == 0 ? null : clientId;
  }

  /// User id of the active account once resolved; null before that.
  int? get activeAccountUserId => _activeAccountUserId;

  /// Every kept copy of the ACTIVE account, oldest first — the order the
  /// mirror saw the messages. Bounded by [maxEntries]; the viewer reverses
  /// for display. Records of other accounts are never surfaced here.
  List<MessageHistoryEntry> get entries => List.unmodifiable(
    _byKey.values.where((entry) => entry.accountUserId == _activeAccountUserId),
  );

  /// The ACTIVE account's kept copies that ARE history: deleted, or carrying
  /// an edit trail. Plain active copies are recorded only so a later deletion
  /// or edit has its base, and never appear in a history list.
  List<MessageHistoryEntry> get historyEntries => List.unmodifiable(
    _byKey.values.where(
      (entry) =>
          entry.accountUserId == _activeAccountUserId && entry.hasHistory,
    ),
  );

  /// Newest first, one chat of the active account, excluded chats are hidden.
  List<MessageHistoryEntry> entriesFor(int chatId) => isChatExcluded(chatId)
      ? const []
      : List.unmodifiable(
          _byKey.values.where(
            (entry) =>
                entry.accountUserId == _activeAccountUserId &&
                entry.chatId == chatId,
          ),
        );

  /// [entriesFor] narrowed to what the history viewer lists.
  List<MessageHistoryEntry> historyEntriesFor(int chatId) =>
      isChatExcluded(chatId)
      ? const []
      : List.unmodifiable(
          _byKey.values.where(
            (entry) =>
                entry.accountUserId == _activeAccountUserId &&
                entry.chatId == chatId &&
                entry.hasHistory,
          ),
        );

  /// Looks up an entry of the ACTIVE account. Kept for the viewer, whose
  /// whole data model is the active account; every chat-surface caller
  /// must resolve the owning slot's user id instead (ChatViewModel's
  /// mirrorEntryForMessage) — a transcript can outlive the account switch
  /// that changes what "active" means.
  @visibleForTesting
  MessageHistoryEntry? entry(int chatId, int messageId) =>
      _activeAccountUserId == null
      ? null
      : _byKey['$_activeAccountUserId:$chatId:$messageId'];

  /// Looks up an entry of an EXPLICIT account — the reply-anchor filler in
  /// the chat view model knows the owning slot's user id and must not read
  /// whichever account happens to be active.
  MessageHistoryEntry? entryFor(int accountUserId, int chatId, int messageId) =>
      allowTelegramTosViolations
      ? _byKey['$accountUserId:$chatId:$messageId']
      : null;

  /// Deleted kept copies of one chat of one account, oldest first — the
  /// ghost-bubble source. Reads by explicit account id so a chat view of a
  /// non-active slot (desktop multi-window) still gets its own ghosts.
  /// [topicId] narrows the result to one forum topic (0 = whole chat).
  List<MessageHistoryEntry> deletedEntriesFor(
    int accountUserId,
    int chatId, {
    int topicId = 0,
  }) {
    if (!allowTelegramTosViolations) return const [];
    if (_excludedChatsByAccount[accountUserId]?.contains(chatId) ?? false) {
      // An excluded chat owes no ghosts — belt and braces against rows that
      // predate an exclusion (stale disk batch, import, older build).
      return const [];
    }
    return List.unmodifiable(
      _byKey.values.where((entry) {
        if (entry.accountUserId != accountUserId ||
            entry.chatId != chatId ||
            entry.state != MessageHistoryState.deleted) {
          return false;
        }
        // A topic-scoped transcript shows only its own topic's ghosts.
        // Unattributed rows (topicId 0: pre-capture rows and General's
        // no-topic-id arrivals, which the forum index maps to General)
        // belong to the General view alone — mirroring
        // rawMessageBelongsToForumTopic's fallback rule.
        if (topicId != 0) {
          if (entry.topicId != 0) return entry.topicId == topicId;
          return topicId == generalForumTopicId;
        }
        return true;
      }),
    );
  }

  int get entryCount => _byKey.length;

  /// Whether [ensureLoaded] has finished reading the mirror file. A cold
  /// start opens a chat before the file lands; callers that reconcile
  /// against the loaded state use this to know an empty answer is final.
  bool get isLoaded => _loaded;

  /// Live evidence from a transcript: [messageId] exists in [chatId] right
  /// now. A kept copy that is still marked deleted is therefore a FALSE
  /// deletion (TDLib's cache-unload updates were recorded as deletions by
  /// older builds, or a deletion update raced a re-fetch) and becomes active
  /// again. Batched through a microtask: parsing a history page calls this
  /// per message and the store notifies once.
  void confirmAlive(int accountUserId, int chatId, int messageId) {
    if (!allowTelegramTosViolations) return;
    if (messageId <= 0) return;
    final key = '$accountUserId:$chatId:$messageId';
    final entry = _byKey[key];
    if (entry == null || entry.state != MessageHistoryState.deleted) return;
    _pendingAliveKeys.add(key);
    if (_aliveFlushScheduled) return;
    _aliveFlushScheduled = true;
    scheduleMicrotask(_flushPendingAlive);
  }

  void _flushPendingAlive() {
    _aliveFlushScheduled = false;
    if (_disposed) {
      _pendingAliveKeys.clear();
      return;
    }
    var changed = false;
    for (final key in _pendingAliveKeys) {
      final entry = _byKey[key];
      if (entry == null || entry.state != MessageHistoryState.deleted) {
        continue;
      }
      _byKey[key] = entry.copyWith(
        state: MessageHistoryState.active,
        deletedAt: 0,
      );
      changed = true;
    }
    _pendingAliveKeys.clear();
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
  }

  bool isChatExcluded(int chatId) =>
      _activeAccountUserId != null &&
      (_excludedChatsByAccount[_activeAccountUserId]?.contains(chatId) ??
          false);

  /// Exclusion check for an EXPLICIT account — a surface pinned to one
  /// account (a desktop utility window's chat info) must not read the
  /// primary window's active account.
  bool isChatExcludedFor(int accountUserId, int chatId) =>
      _excludedChatsByAccount[accountUserId]?.contains(chatId) ?? false;

  Set<int> get excludedChats => Set.unmodifiable(
    _excludedChatsByAccount[_activeAccountUserId] ?? const {},
  );

  // ---------------------------------------------------------------------------
  // Bootstrap (guarded — with the flag off nothing below may run)
  // ---------------------------------------------------------------------------

  /// Reads the per-account exclusions of every account seen so far. Called
  /// from the app bootstrap with the shared prefs; a no-op unless the
  /// feature is compiled in. The pre-account v1 exclusion key is not
  /// migrated: an exclusion written before account identity existed cannot
  /// be attributed to an account without guessing.
  void initialize(SharedPreferences prefs) {
    if (!allowTelegramTosViolations) return;
    _prefs = prefs;
    _excludedChatsByAccount.clear();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefsKeyPrefix)) continue;
      final suffix = key.substring(_prefsKeyPrefix.length);
      final accountUserId = int.tryParse(suffix);
      if (accountUserId == null) continue;
      final raw = prefs.getStringList(key) ?? const <String>[];
      final excluded = raw.map(int.tryParse).whereType<int>().toSet();
      _excludedChatsByAccount[accountUserId] = excluded;
    }
    notifyListeners();
  }

  /// Subscribes the mirror to the TDLib updates it needs. Called once from
  /// the app bootstrap after [initialize].
  void startObserving() {
    if (!allowTelegramTosViolations) return;
    if (_observing) return;
    _observing = true;
    _tdSub = _openUpdates(observedUpdateTypes).listen(_onTdUpdate);
    _activeSlotSub = _openActiveSlotChanges().listen((_) {
      _refreshActiveAccount();
    });
    _refreshActiveAccount();
  }

  /// The typed update stream the mirror subscribes to. Tests replace this to
  /// drive updates without a TDLib client.
  @visibleForTesting
  Stream<Map<String, dynamic>> Function(Iterable<String> types)? updateSource;

  Stream<Map<String, dynamic>> _openUpdates(Iterable<String> types) {
    final source = updateSource;
    if (source != null) return source(types);
    // Active-only: background accounts' chats are not open here, so their
    // history and edits are not recorded — mirroring is tied to the account
    // the user is actually looking at. Updates that do reach this stream
    // still carry '@client_id' and are attributed per client, so a slot
    // switch mid-flight never misattributes a queued update.
    return TdClient.shared.updatesOfAny(types);
  }

  Stream<int> _openActiveSlotChanges() {
    final source = activeSlotChangeSource;
    if (source != null) return source();
    return TdClient.shared.subscribeActiveSlotChanges();
  }

  /// Re-resolves the active account's user id when the active client
  /// changes; the viewer and the exclusion APIs read the cached result.
  /// EVERY terminal state notifies: the switch itself (the account context
  /// changed, so the viewer must re-read immediately, dropping the previous
  /// account's rows), success (rows appear) and failure (empty is the
  /// terminal state, so the stale rows must leave the screen there too).
  void _refreshActiveAccount() {
    final clientId = _currentClientId;
    if (clientId == null) {
      final hadContext =
          _activeAccountUserId != null || _activeAccountUserIdSource != null;
      _activeAccountUserId = null;
      _activeAccountUserIdSource = null;
      if (hadContext) notifyListeners();
      return;
    }
    if (_activeAccountUserIdSource == clientId &&
        _activeAccountUserId != null) {
      return;
    }
    _activeAccountUserIdSource = clientId;
    _activeAccountUserId = null;
    notifyListeners();
    final generation = _generation;
    unawaited(
      // A test (or a falling-back production) resolver may complete with an
      // error; the failure is a terminal state of the resolution, so it is
      // flattened to null here and notified like every other outcome.
      _resolveAccountUserId(
        clientId,
      ).then<int?>((userId) => userId, onError: (Object _) => null).then((
        userId,
      ) {
        if (_disposed || _generation != generation) return;
        // A newer active client may have taken over while this one resolved.
        if (_currentClientId != clientId || userId == null) {
          notifyListeners();
          return;
        }
        _activeAccountUserId = userId;
        notifyListeners();
      }),
    );
  }

  Future<int?> _resolveAccountUserId(int clientId) =>
      _resolver.resolve(clientId);

  @visibleForTesting
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _tdSub?.cancel();
    _tdSub = null;
    _activeSlotSub?.cancel();
    _activeSlotSub = null;
    _observing = false;
    _persistTimer?.cancel();
    _persistTimer = null;
    super.dispose();
  }

  /// Seeds the active account's identity for tests; stands in for what
  /// [_refreshActiveAccount] resolves from TDLib in production.
  @visibleForTesting
  void debugSetActiveAccount(int accountUserId) {
    if (!allowTelegramTosViolations) return;
    _activeAccountUserId = accountUserId;
    _activeAccountUserIdSource = null;
    notifyListeners();
  }

  /// Seeds in-memory copies for tests; never touches persistence. Guarded
  /// like every mutator: with the flag off the store stays empty no matter
  /// what reaches it.
  @visibleForTesting
  void debugSeed(List<MessageHistoryEntry> seeded) {
    if (!allowTelegramTosViolations) return;
    for (final entry in seeded) {
      _byKey[entry.key] = entry;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  void _onTdUpdate(Map<String, dynamic> update) {
    if (!allowTelegramTosViolations) return;
    // Every TDLib update is stamped with the client that received it
    // (updatesOfAny(allAccounts:true) documents this); resolving that to an
    // account user id is what keeps two accounts with identical chat/message
    // ids in two records. Updates without a client id are dropped: there is
    // no way to attribute them, and guessing the active account would
    // misattribute history whenever the active account changes.
    final clientId = update.integer('@client_id');
    if (clientId == null || clientId == 0) return;
    unawaited(_handleUpdateForClient(clientId, update));
  }

  /// Handles one update for [clientId]. The update joins its client's chain
  /// BEFORE identity resolution, so a client's records apply in TDLib
  /// arrival order even when a lookup is slow or stuck; different clients
  /// resolve and record concurrently. BOTH epochs are captured at ARRIVAL
  /// so invalidations that land while the update is queued or resolving
  /// can drop it before it writes.
  Future<void> _handleUpdateForClient(
    int clientId,
    Map<String, dynamic> update,
  ) async {
    final arrivalGeneration = _generation;
    final arrivalScopeEpoch = _scopeEpoch;
    final previous = _clientWorkers[clientId] ?? Future<void>.value();
    final worker = previous
        .catchError((_) {})
        .then(
          (_) => _processUpdateForClient(
            clientId,
            update,
            arrivalGeneration,
            arrivalScopeEpoch,
          ),
        );
    _clientWorkers[clientId] = worker;
    try {
      await worker;
    } finally {
      if (identical(_clientWorkers[clientId], worker)) {
        unawaited(_clientWorkers.remove(clientId));
      }
    }
  }

  /// The chain job of one update: wait for the client's identity (memoized
  /// per client), then record in arrival order. A failed resolution drops
  /// this client's queued events for this attempt — unattributable updates
  /// are never guessed — and the next arrival starts a fresh attempt. An
  /// invalidation that landed after the update arrived drops the write:
  /// pending work can never resurrect cleared or removed history. The drop
  /// check is SCOPED — only the removed account's or cleared chat's own
  /// queued updates are dropped; every other account's and chat's pending
  /// work records as usual. Only the global generation (clearAll, dispose)
  /// cancels across all scopes.
  Future<void> _processUpdateForClient(
    int clientId,
    Map<String, dynamic> update,
    int arrivalGeneration,
    int arrivalScopeEpoch,
  ) async {
    final userId = await _identityOf(clientId);
    if (userId == null) return; // unattributable — never guess
    final removedAt = _removedAccountAt[userId];
    if (removedAt != null && removedAt > arrivalScopeEpoch) {
      return; // its account was removed after the update arrived
    }
    final chatId = _updateChatId(update);
    if (chatId != null) {
      final clearedAt = _clearedChatAt['$userId:$chatId'];
      if (clearedAt != null && clearedAt > arrivalScopeEpoch) {
        return; // its chat was cleared after the update arrived
      }
    }
    if (_disposed || _generation != arrivalGeneration) return;
    unawaited(_recordUpdate(userId, update));
    // New evidence about the ACTIVE client's identity: when the active
    // resolution already failed (or was dropped), a successful resolution
    // here reconciles the active account instead of leaving the viewer
    // empty until the next slot switch.
    if (clientId == _activeAccountUserIdSource &&
        _activeAccountUserId == null) {
      _activeAccountUserId = userId;
      notifyListeners();
    }
  }

  /// The chat id an update targets, when the update payload carries one
  /// (all four observed update types do). Null for an update whose payload
  /// is missing or malformed — there is then no chat scope to check.
  static int? _updateChatId(Map<String, dynamic> update) {
    switch (update.type) {
      case 'updateNewMessage':
        return update.obj('message')?.int64('chat_id');
      case 'updateMessageEdited':
      case 'updateMessageContent':
      case 'updateDeleteMessages':
        return update.int64('chat_id');
      case 'updateChat':
        return update.obj('chat')?.int64('id');
    }
    return null;
  }

  /// Identity resolution memoized per client: concurrent events share the
  /// in-flight lookup, and a KNOWN identity stays cached for the client's
  /// following events. A failed or unresolved lookup (exception, null) is
  /// dropped from the memo so the next arrival starts a fresh attempt
  /// instead of caching the failure; a global wipe (clearAll) or disposal
  /// forgets in-flight attempts too. SCOPED invalidations (removing one
  /// account, clearing one chat) touch neither the memo nor in-flight
  /// lookups — a client's identity does not change when an unrelated
  /// account is removed — the scope filter runs per resolved account in
  /// [_processUpdateForClient].
  Future<int?> _identityOf(int clientId) {
    final inFlight = _identityFutures[clientId];
    if (inFlight != null) return inFlight;
    final generation = _generation;
    // The lookup starts synchronously (no extra event-loop hop): the chain
    // job of a just-arrived update must complete within the same drain, the
    // way the per-account worker did before arrival-order queueing existed.
    Future<int?> settle(Future<int?> lookup) => lookup.then<int?>((userId) {
      final invalidated = _disposed || _generation != generation;
      final resolved = invalidated ? null : userId;
      if (resolved == null) _identityFutures.remove(clientId);
      return resolved;
    });
    Future<int?> attempt;
    try {
      attempt = settle(_resolver.resolve(clientId)).catchError((Object _) {
        // Resolution failed: forget the attempt so a later event retries.
        _identityFutures.remove(clientId);
        return null;
      });
    } catch (_) {
      // A resolver that throws synchronously (instead of returning a failed
      // future) resolves to nothing; the next arrival starts a new attempt.
      return Future<int?>.value();
    }
    _identityFutures[clientId] = attempt;
    return attempt;
  }

  Future<void> _recordUpdate(int accountUserId, Map<String, dynamic> update) {
    switch (update.type) {
      case 'updateNewMessage':
        _recordIncomingMessage(accountUserId, update.obj('message'));
      case 'updateMessageEdited':
        _rememberEditDate(accountUserId, update);
      case 'updateMessageContent':
        _recordContentUpdate(accountUserId, update);
      case 'updateDeleteMessages':
        _recordDeletedMessages(accountUserId, update);
      case 'updateChat':
        _recordChatLiveness(accountUserId, update);
      case 'updateNewChat':
        _recordNewChatType(accountUserId, update);
      case 'updateFile':
        _recordFileUpdate(update);
    }
    return Future<void>.value();
  }

  /// Mirrors one incoming message. Also runs for messages that come back
  /// (cache eviction refetch, album resend): those refresh the copy but keep
  /// the recorded history, and a message deleted earlier becomes active
  /// again because it exists again.
  void recordIncomingMessage(Map<String, dynamic>? message) =>
      _recordIncomingMessage(_activeAccountUserId, message);

  void _recordIncomingMessage(
    int? accountUserId,
    Map<String, dynamic>? message,
  ) {
    if (!allowTelegramTosViolations) return;
    if (accountUserId == null || message == null) return;
    final settings = MessageHistorySettings.shared;
    final chatId = message.int64('chat_id');
    // The message object carries its own id in `id` (message_id is the field
    // name on the update wrappers, not on message).
    final messageId = message.integer('id');
    if (chatId == null || messageId == null) return;
    // The mirror keeps what the counterpart could take away: only incoming
    // messages. The account's own outgoing ones stay Telegram's business.
    // Saved Messages (chat id == own user id) is incoming from itself and is
    // still kept — the self dialog is incoming from this account's other devices.
    final isOutgoing = message.boolean('is_outgoing') ?? false;
    final isSelfChat = chatId == accountUserId;
    if (isOutgoing && !isSelfChat) return;
    if (_excludedChatsByAccount[accountUserId]?.contains(chatId) ?? false) {
      return;
    }

    final key = '$accountUserId:$chatId:$messageId';
    final content = message.obj('content');
    final primaryMedia = _primaryMedia(content);
    final existing = _byKey[key];
    if (existing != null) {
      final refreshed = existing.copyWith(
        text: _messageText(content) ?? existing.text,
        kindKey: _messageKindKey(content) ?? '',
        senderId: _senderId(message) ?? existing.senderId,
        state: MessageHistoryState.active,
        deletedAt: 0,
        topicId: existing.topicId == 0
            ? _messageTopicId(message)
            : existing.topicId,
        mediaWidth: existing.mediaWidth > 0
            ? existing.mediaWidth
            : primaryMedia?.width ?? 0,
        mediaHeight: existing.mediaHeight > 0
            ? existing.mediaHeight
            : primaryMedia?.height ?? 0,
        mediaDuration: existing.mediaDuration > 0
            ? existing.mediaDuration
            : primaryMedia?.duration ?? 0,
        mediaFileName: existing.mediaFileName.isNotEmpty
            ? existing.mediaFileName
            : primaryMedia?.fileName ?? '',
        mediaMimeType: existing.mediaMimeType.isNotEmpty
            ? existing.mediaMimeType
            : primaryMedia?.mimeType ?? '',
        mediaFileId: existing.mediaFileId > 0
            ? existing.mediaFileId
            : primaryMedia?.fileId ?? 0,
        mediaSourcePath: existing.mediaSourcePath.isNotEmpty
            ? existing.mediaSourcePath
            : primaryMedia?.localPath ?? '',
      );
      if (refreshed == existing) return;
      _byKey[key] = refreshed;
      notifyListeners();
      _schedulePersist();
      _snapshotMediaOf(accountUserId, chatId, messageId, message);
      return;
    }

    // Recording a brand-new copy requires the deleted-recording switch AND
    // the conversation-type switch of this chat's class; a known copy is
    // always refreshed so re-arrivals keep existing mirrors truthful even
    // after the switches were turned off.
    if (!settings.recordDeleted ||
        !recordsChatType(accountUserId, chatId, message)) {
      return;
    }

    final date = message.integer('date') ?? 0;
    _byKey[key] = MessageHistoryEntry(
      accountUserId: accountUserId,
      chatId: chatId,
      messageId: messageId,
      senderId: _senderId(message) ?? 0,
      date: date,
      text: _messageText(content) ?? '',
      kindKey: _messageKindKey(content) ?? '',
      state: MessageHistoryState.active,
      deletedAt: 0,
      events: const [],
      topicId: _messageTopicId(message),
      mediaWidth: primaryMedia?.width ?? 0,
      mediaHeight: primaryMedia?.height ?? 0,
      mediaDuration: primaryMedia?.duration ?? 0,
      mediaFileName: primaryMedia?.fileName ?? '',
      mediaMimeType: primaryMedia?.mimeType ?? '',
      mediaFileId: primaryMedia?.fileId ?? 0,
      mediaSourcePath: primaryMedia?.localPath ?? '',
    );
    _trim();
    notifyListeners();
    _schedulePersist();
    _snapshotMediaOf(accountUserId, chatId, messageId, message);
  }

  /// Starts snapshotting a mirrored message's media. TDLib usually has not
  /// finished downloading the file when the message arrives — the bubble
  /// later requests the size it paints — so every candidate file id is
  /// registered and [updateFile] copies the file the moment it lands. A file
  /// already on disk is copied right away.
  void _snapshotMediaOf(
    int accountUserId,
    int chatId,
    int messageId,
    Map<String, dynamic> message,
  ) {
    final candidates = _mediaCandidates(message.obj('content'));
    if (candidates.isEmpty) return;
    if (!_snapshotsEnabledFor(accountUserId, chatId, message)) return;
    final entryKey = '$accountUserId:$chatId:$messageId';
    _trackMediaCandidates(entryKey, candidates);
    // Candidates are largest first: the first complete main file is the best
    // one, and the first complete poster fills the preview slot.
    var mainCopied = false;
    var posterCopied = false;
    for (final candidate in candidates) {
      if (!_fileIsComplete(candidate.file)) continue;
      if (candidate.poster ? posterCopied : mainCopied) continue;
      if (candidate.poster) {
        posterCopied = true;
      } else {
        mainCopied = true;
      }
      unawaited(
        _snapshotCandidate(
          entryKey,
          candidate,
          upgrade: false,
          poster: candidate.poster,
        ),
      );
      if (mainCopied && posterCopied) break;
    }
    // Nothing usable on disk: ask for the media now. A chat the user never
    // opens has no row that would request the file, so without this the
    // mirror records an entry whose snapshot never appears — the reference
    // client avoids that by queueing the download from DownloadController the
    // moment the update arrives. The prefetch still obeys the auto-download
    // preset and runs below foreground priority.
    if (!mainCopied) {
      unawaited(MediaPrefetch.shared.prefetchTdContent(message.obj('content')));
    }
  }

  /// The media a content payload can keep, largest first. A photo carries one
  /// file per size; the biggest one is normally downloaded only when the user
  /// opens the photo, so EVERY size is a candidate — whichever lands on disk
  /// first becomes the snapshot, and a later, larger one upgrades it.
  ///
  /// Video / animation / video note / sticker entries add their `thumbnail`
  /// as a POSTER candidate: the content file itself is a video or a `.tgs`,
  /// which no image widget can paint, so the bubble previews the poster and
  /// taps open the original. The `@type` wrappers nest the real file one level
  /// down (`video.video`, `document.document`, ...).
  static List<_MediaCandidate> _mediaCandidates(Map<String, dynamic>? content) {
    if (content == null) return const [];
    switch (content.type) {
      case 'messagePhoto':
        final sizes = content.obj('photo')?.objects('sizes');
        if (sizes == null) return const [];
        final candidates = <_MediaCandidate>[];
        for (final size in sizes) {
          final file = size.obj('photo');
          if (file == null) continue;
          candidates.add(
            _MediaCandidate(
              file: file,
              width: size.integer('width') ?? 0,
              height: size.integer('height') ?? 0,
            ),
          );
        }
        candidates.sort((a, b) => b.area.compareTo(a.area));
        return candidates;
      case 'messageVideo':
      case 'messageAnimation':
        final media = content.obj('video') ?? content.obj('animation');
        final file = media?.obj('video') ?? media?.obj('animation');
        if (media == null || file == null) return const [];
        return [
          _MediaCandidate(
            file: file,
            width: media.integer('width') ?? 0,
            height: media.integer('height') ?? 0,
            duration: media.integer('duration') ?? 0,
            fileName: media.str('file_name') ?? '',
            mimeType: media.str('mime_type') ?? '',
          ),
          ?_posterCandidate(media),
        ];
      case 'messageDocument':
        final document = content.obj('document');
        final file = document?.obj('document');
        if (document == null || file == null) return const [];
        return [
          _MediaCandidate(
            file: file,
            fileName: document.str('file_name') ?? '',
            mimeType: document.str('mime_type') ?? '',
          ),
        ];
      case 'messageVideoNote':
        final note = content.obj('video_note');
        final file = note?.obj('video');
        if (note == null || file == null) return const [];
        final length = note.integer('length') ?? 0;
        return [
          _MediaCandidate(
            file: file,
            width: length,
            height: length,
            duration: note.integer('duration') ?? 0,
            mimeType: 'video/mp4',
          ),
          ?_posterCandidate(note),
        ];
      case 'messageSticker':
        final sticker = content.obj('sticker');
        final file = sticker?.obj('sticker');
        if (sticker == null || file == null) return const [];
        return [
          _MediaCandidate(
            file: file,
            width: sticker.integer('width') ?? 0,
            height: sticker.integer('height') ?? 0,
          ),
          ?_posterCandidate(sticker),
        ];
      case 'messageVoiceNote':
        // messageVoiceNote nests the file one level deeper: voice_note.voice.
        final voice = content.obj('voice_note');
        final file = voice?.obj('voice');
        if (file == null) return const [];
        return [
          _MediaCandidate(
            file: file,
            duration: voice?.integer('duration') ?? 0,
            mimeType: voice?.str('mime_type') ?? '',
          ),
        ];
      case 'messageAudio':
        // messageAudio nests the file one level deeper: audio.audio.
        final audio = content.obj('audio');
        final file = audio?.obj('audio');
        if (file == null) return const [];
        return [
          _MediaCandidate(
            file: file,
            duration: audio?.integer('duration') ?? 0,
            fileName: audio?.str('file_name') ?? '',
            mimeType: audio?.str('mime_type') ?? '',
          ),
        ];
    }
    return const [];
  }

  /// The `thumbnail` of a media wrapper as a poster candidate, null when the
  /// wrapper has none. A thumbnail is a `photoSize`: the file lives in `photo`.
  static _MediaCandidate? _posterCandidate(Map<String, dynamic> media) {
    final thumbnail = media.obj('thumbnail');
    final file = thumbnail?.obj('photo');
    if (thumbnail == null || file == null) return null;
    return _MediaCandidate(
      file: file,
      width: thumbnail.integer('width') ?? 0,
      height: thumbnail.integer('height') ?? 0,
      poster: true,
    );
  }

  /// Metadata of the media a newly recorded copy remembers without
  /// registering anything: the largest candidate, whose file id also survives
  /// a restart so a later completion can still be picked up.
  static _MediaCandidate? _primaryMedia(Map<String, dynamic>? content) {
    for (final candidate in _mediaCandidates(content)) {
      if (!candidate.poster) return candidate;
    }
    return null;
  }

  /// Registers every candidate file of one kept copy. A file id shared by
  /// several messages (a forwarded photo) keeps all of their keys, so one
  /// download fills every copy.
  void _trackMediaCandidates(
    String entryKey,
    List<_MediaCandidate> candidates,
  ) {
    for (final candidate in candidates) {
      final id = candidate.fileId;
      if (id <= 0) continue;
      final tracked = _trackedMedia.putIfAbsent(
        id,
        () => _TrackedMediaFile(
          width: candidate.width,
          height: candidate.height,
          poster: candidate.poster,
        ),
      );
      // The file OBJECT is refreshed from updateFile (the record that
      // matters); keeping every arrival payload alive would cost megabytes
      // for a full-size mirror.
      tracked
        ..width = candidate.width
        ..height = candidate.height
        ..poster = candidate.poster;
      tracked.entryKeys.add(entryKey);
      _entryMediaFileIds.putIfAbsent(entryKey, () => <int>{}).add(id);
    }
  }

  /// Drops one kept copy's registrations; a file nobody waits on any more is
  /// forgotten so the update stream stops touching it.
  void _forgetTrackedMedia(String entryKey) {
    final ids = _entryMediaFileIds.remove(entryKey);
    if (ids == null) return;
    for (final id in ids) {
      final tracked = _trackedMedia[id];
      if (tracked == null) continue;
      tracked.entryKeys.remove(entryKey);
      if (tracked.entryKeys.isEmpty) _trackedMedia.remove(id);
    }
  }

  void _forgetTrackedMediaWhere(bool Function(String entryKey) matches) {
    for (final entryKey in _entryMediaFileIds.keys.toList(growable: false)) {
      if (matches(entryKey)) _forgetTrackedMedia(entryKey);
    }
  }

  /// [updateFile]: a tracked download progressed. A completed file is copied
  /// into the mirror — the only chance a message's media has, because once
  /// the message is deleted its file reference is gone.
  void _recordFileUpdate(Map<String, dynamic> update) {
    final file = update.obj('file');
    if (file == null) return;
    final fileId = file.integer('id');
    if (fileId == null) return;
    final tracked = _trackedMedia[fileId];
    if (tracked == null) return;
    tracked.file = file;
    if (!_fileIsComplete(file)) return;
    unawaited(_snapshotTrackedFile(fileId));
  }

  Future<void> _snapshotTrackedFile(int fileId) async {
    final tracked = _trackedMedia[fileId];
    final file = tracked?.file;
    if (tracked == null || file == null) return;
    for (final entryKey in tracked.entryKeys.toList(growable: false)) {
      final entry = _byKey[entryKey];
      if (entry == null) continue;
      final upgrade =
          !tracked.poster &&
          _candidateImproves(entry, tracked.width, tracked.height);
      if (tracked.poster
          ? entry.mediaPosterPath.isNotEmpty
          : entry.mediaPath.isNotEmpty && !upgrade) {
        continue;
      }
      final parts = entryKey.split(':');
      if (parts.length != 3) continue;
      final accountUserId = int.tryParse(parts[0]);
      final chatId = int.tryParse(parts[1]);
      if (accountUserId == null || chatId == null) continue;
      if (!_snapshotsEnabledFor(accountUserId, chatId, null)) continue;
      await _snapshotCandidate(
        entryKey,
        _MediaCandidate(
          file: file,
          width: tracked.width,
          height: tracked.height,
          poster: tracked.poster,
        ),
        upgrade: upgrade,
        poster: tracked.poster,
      );
    }
  }

  /// Whether a file of [width]x[height] is worth replacing the entry's
  /// existing snapshot with. An empty path always is; an unknown candidate
  /// size never replaces a known larger one.
  static bool _candidateImproves(
    MessageHistoryEntry entry,
    int width,
    int height,
  ) {
    if (entry.mediaPath.isEmpty) return true;
    if (width <= 0 || height <= 0) return false;
    if (entry.mediaWidth <= 0 || entry.mediaHeight <= 0) return true;
    return width * height > entry.mediaWidth * entry.mediaHeight;
  }

  /// Per-entry snapshot chain: a photo's sizes can complete back to back, and
  /// two copies writing the same target file at once would corrupt it. Work
  /// for one kept copy is serialised; different messages stay parallel.
  final Map<String, Future<void>> _snapshotWork = {};

  /// Copies one candidate and records it on the entry. [upgrade] may replace
  /// an existing snapshot (the file is known to be larger); otherwise the
  /// first copy wins, so a snapshot is never taken for content the mirror did
  /// not see arrive.
  Future<void> _snapshotCandidate(
    String entryKey,
    _MediaCandidate candidate, {
    required bool upgrade,
    bool? poster,
  }) {
    final previous = _snapshotWork[entryKey] ?? Future<void>.value();
    final work = previous
        .catchError((Object _) {})
        .then(
          (_) => _runSnapshotCandidate(
            entryKey,
            candidate,
            upgrade: upgrade,
            poster: poster ?? candidate.poster,
          ),
        );
    _snapshotWork[entryKey] = work;
    return work.whenComplete(() {
      if (identical(_snapshotWork[entryKey], work)) {
        _snapshotWork.remove(entryKey);
      }
    });
  }

  Future<void> _runSnapshotCandidate(
    String entryKey,
    _MediaCandidate candidate, {
    required bool upgrade,
    required bool poster,
  }) async {
    final parts = entryKey.split(':');
    if (parts.length != 3) return;
    final accountUserId = int.tryParse(parts[0]);
    final chatId = int.tryParse(parts[1]);
    final messageId = int.tryParse(parts[2]);
    if (accountUserId == null || chatId == null || messageId == null) return;
    final generation = _generation;
    final path = await _media().snapshot(
      candidate.file,
      accountUserId: accountUserId,
      chatId: chatId,
      messageId: messageId,
      replaceExisting: upgrade,
    );
    if (path == null) return;
    // The copy raced a global wipe or disposal: the store's state moved on,
    // so the late path is dropped instead of resurrecting the entry (and
    // notifyListeners on a disposed store).
    if (_disposed || _generation != generation) return;
    final existing = _byKey[entryKey];
    if (existing == null) return;
    if (poster) {
      if (existing.mediaPosterPath.isNotEmpty) return;
      _byKey[entryKey] = existing.copyWith(mediaPosterPath: path);
      notifyListeners();
      _schedulePersist();
      return;
    }
    if (existing.mediaPath.isNotEmpty && !upgrade) return;
    if (existing.mediaPath.isNotEmpty &&
        !_candidateImproves(existing, candidate.width, candidate.height)) {
      return;
    }
    _byKey[entryKey] = existing.copyWith(
      mediaPath: path,
      mediaWidth: candidate.width,
      mediaHeight: candidate.height,
      mediaDuration: candidate.duration,
      mediaFileName: candidate.fileName,
      mediaMimeType: candidate.mimeType,
      mediaFileId: candidate.fileId,
      mediaSourcePath: candidate.localPath,
    );
    notifyListeners();
    _schedulePersist();
  }

  /// TDLib's own "this file is whole on disk" test.
  static bool _fileIsComplete(Map<String, dynamic> file) {
    final local = file.obj('local');
    if (local == null) return false;
    if (local.boolean('is_downloading_completed') != true) return false;
    final path = local.str('path');
    return path != null && path.isNotEmpty;
  }

  /// Whether snapshots may be taken for this message's conversation. The
  /// snapshot switches gate by conversation class (user/secret chats are
  /// "private", basic groups/supergroups "groups", channels "channels"),
  /// AND the recording gates apply first: a chat whose recording switch is
  /// off records nothing at all — text or media — and a bot chat snapshots
  /// only under the bot recording switch.
  bool _snapshotsEnabledFor(
    int accountUserId,
    int chatId,
    Map<String, dynamic>? message,
  ) {
    final settings = MessageHistorySettings.shared;
    if (!settings.snapshotPrivate &&
        !settings.snapshotGroups &&
        !settings.snapshotChannels) {
      return false;
    }
    if (!recordsChatType(accountUserId, chatId, message)) return false;
    // TDLib chat ids: users are positive; basic groups −1e13.., supergroups
    // and channels −1e14.. The chat type is not carried on the message, so
    // the id class decides. Self chat snapshots with "private".
    if (chatId > 0) return settings.snapshotPrivate;
    if (chatId > -1000000000000) return settings.snapshotGroups;
    return _supergroupGate(
      accountUserId,
      chatId,
      settings.snapshotGroups,
      settings.snapshotChannels,
    );
  }

  MessageMediaSnapshotter _media() =>
      mediaSnapshotter ?? MessageMediaSnapshotter.shared;

  // ---------------------------------------------------------------------------
  // Chat-type gates (bot detection + per-type recording)
  // ---------------------------------------------------------------------------

  /// Bot chats the store has seen an updateChat for, keyed per account.
  /// A bot dialog is a private chat, but recording its service messages is
  /// a separate opt-in, so the chat type observed from
  /// TDLib is cached here — chat ids alone cannot tell a bot dialog from a
  /// human one.
  final Map<String, bool> _botChats = {};

  /// (account, chat) → true when the supergroup is a channel. Only ids in the
  /// -100… range need it; basic groups and private chats are decided by id.
  /// Unknown supergroups default to channel so a groups-only setting never
  /// starts recording channel content before the type is known.
  final Map<String, bool> _channelChats = {};

  /// Whether the mirror may record [chatId] for [accountUserId] under the
  /// per-type switches. Bot gating applies to DIALOGS only (a private chat
  /// with a bot); the raw message carries the sender's is_bot when the
  /// chat type is not cached yet — updates often arrive before updateChat.
  bool recordsChatType(
    int accountUserId,
    int chatId,
    Map<String, dynamic>? message,
  ) {
    final settings = MessageHistorySettings.shared;
    // The bot question exists only for DIALOGS: a private chat with a bot.
    // A bot posting inside a group or channel is still group/channel
    // content — letting the sender's is_bot flip the chat's gate would drop
    // the whole conversation the moment one bot posts there.
    if (chatId > 0) {
      final isBot =
          _botChats['$accountUserId:$chatId'] ?? _sniffBotFromMessage(message);
      if (isBot) return settings.recordBots;
      return settings.recordPrivate;
    }
    if (chatId > -1000000000000) return settings.recordGroups;
    return _supergroupGate(
      accountUserId,
      chatId,
      settings.recordGroups,
      settings.recordChannels,
    );
  }

  /// Applies the groups/channels switches to a -100… chat. Only the chat's
  /// type tells a supergroup from a channel; TDLib delivers it through
  /// updateNewChat/updateChat. Until it is known, honouring EITHER switch is
  /// the safe default: ids cannot tell the classes apart, supergroups
  /// outnumber channels, and treating an unknown supergroup as a channel
  /// silently disabled a groups-only setting for the groups users actually
  /// have.
  bool _supergroupGate(
    int accountUserId,
    int chatId,
    bool groups,
    bool channels,
  ) {
    final isChannel = _channelChats['$accountUserId:$chatId'];
    if (isChannel == null) return groups || channels;
    return isChannel ? channels : groups;
  }

  /// Best-effort bot detection from the message payload itself: only a
  /// sender explicitly marked `is_bot` counts. via_bot and inline keyboards
  /// do NOT (a human message posted through a bot, or a bot-generated group
  /// post, would otherwise misclassify a whole human chat as a bot chat —
  /// and updateChat only re-seeds the truth when it happens to arrive).
  static bool _sniffBotFromMessage(Map<String, dynamic>? message) {
    if (message == null) return false;
    final sender = message.obj('sender_id');
    return sender?.type == 'messageSenderUser' &&
        (sender?.boolean('is_bot') ?? false);
  }

  /// Seeds the chat-type caches from an observed chat object. A user-type
  /// chat resolves the bot question definitively (`is_bot` on the type);
  /// other chat types just mark the id as known so the id-class fallback
  /// applies without further sniffing.
  void _rememberChatType(int accountUserId, Map<String, dynamic> chat) {
    final chatId = chat.int64('id');
    if (chatId == null) return;
    final key = '$accountUserId:$chatId';
    final type = chat.obj('type');
    final isBot = type?.boolean('is_bot') ?? false;
    if (type != null) {
      _botChats[key] = isBot;
      if (type.type == 'chatTypeSupergroup') {
        _channelChats[key] = type.boolean('is_channel') ?? true;
      }
    }
  }

  /// updateNewChat carries the full chat, including its type; seed the
  /// classification before any message of that chat arrives.
  void _recordNewChatType(int accountUserId, Map<String, dynamic> update) {
    final chat = update.obj('chat');
    if (chat == null) return;
    _rememberChatType(accountUserId, chat);
  }

  /// The snapshotter the viewer resolves media paths against (tests read
  /// the injected one, production the shared instance).
  MessageMediaSnapshotter get mediaSnapshotterForView => _media();

  /// The injected snapshotter (tests); defaults to the shared one.
  @visibleForTesting
  MessageMediaSnapshotter? mediaSnapshotter;

  /// updateChat: remembers per (account, chat) whether the chat is still
  /// openable. A chat the counterpart destroyed (deleted account, gone
  /// secret chat, or a chat that no longer resolves) marks its kept entries
  /// with `hasLiveChat false` — nothing live remains behind the copy.
  void _recordChatLiveness(int accountUserId, Map<String, dynamic> update) {
    final chat = update.obj('chat');
    if (chat == null) return;
    final chatId = chat.int64('id');
    if (chatId == null) return;
    _rememberChatType(accountUserId, chat);
    final gone = switch (chat.obj('type')?.type) {
      'chatTypeUnknown' => true,
      _ => false,
    };
    if (gone == _deadChats.contains('$accountUserId:$chatId')) return;
    if (gone) {
      _deadChats.add('$accountUserId:$chatId');
    } else {
      _deadChats.remove('$accountUserId:$chatId');
    }
    var changed = false;
    for (final entry in _byKey.values.toList(growable: false)) {
      if (entry.accountUserId != accountUserId || entry.chatId != chatId) {
        continue;
      }
      _byKey[entry.key] = entry.copyWith(hasLiveChat: !gone);
      changed = true;
    }
    if (changed) {
      notifyListeners();
      _schedulePersist();
    }
  }

  /// updateMessageEdited carries the edit time but not the content; the new
  /// content arrives in a following updateMessageContent. Only that pair —
  /// not TDLib's own content generations (dice rolls, live locations) —
  /// produces an edit event. Pending dates are owned by the account whose
  /// client observed the edit.
  void _rememberEditDate(int accountUserId, Map<String, dynamic> update) {
    if (!MessageHistorySettings.shared.recordEdits) return;
    final chatId = update.int64('chat_id');
    final messageId = update.integer('message_id');
    if (chatId == null || messageId == null) return;
    final key = '$accountUserId:$chatId:$messageId';
    final editDate = update.integer('edit_date') ?? 0;
    _pendingEditDates[key] = editDate;

    // Reversed pair: TDLib catch-up delivered the content first. The date
    // completes the revision it was waiting for, and the pending stamp is
    // consumed so a duplicate date cannot record it twice.
    final late = _lateContentUpdates.remove(key);
    if (late == null) return;
    final now = _nowSeconds();
    if (now - late.at > _lateContentWindowSeconds) return;
    _pendingEditDates.remove(key);
    _applyContentRevision(accountUserId, key, editDate, late.update);
  }

  int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Forgets a scope's pending edit pairs — the date and the content half
  /// alike — so a cleared chat or removed account cannot apply either.
  void _forgetPendingEdits(int accountUserId, {int? chatId}) {
    final prefix = chatId == null
        ? '$accountUserId:'
        : '$accountUserId:$chatId:';
    _pendingEditDates.removeWhere((key, _) => key.startsWith(prefix));
    _lateContentUpdates.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Keeps a content payload that arrived without its edited date waiting
  /// for one. Expired waits are dropped on every arrival so a long-lived
  /// store never accumulates generations.
  void _holdLateContent(String key, Map<String, dynamic> update, int now) {
    _lateContentUpdates.removeWhere(
      (_, late) => now - late.at > _lateContentWindowSeconds,
    );
    if (_lateContentUpdates.length >= _lateContentLimit) {
      _lateContentUpdates.remove(_lateContentUpdates.keys.first);
    }
    _lateContentUpdates[key] = (update: update, at: now);
  }

  void _recordContentUpdate(int accountUserId, Map<String, dynamic> update) {
    if (!MessageHistorySettings.shared.recordEdits) return;
    final chatId = update.int64('chat_id');
    final messageId = update.integer('message_id');
    if (chatId == null || messageId == null) return;
    final key = '$accountUserId:$chatId:$messageId';
    final now = _nowSeconds();
    final editDate = _pendingEditDates.remove(key);
    if (editDate == null) {
      // No pending date: either a content generation (dice roll, live
      // location, poll update — it never gets a date and must not become a
      // revision) or the first half of a reversed edit pair. Hold it for a
      // short window; _rememberEditDate applies it if the date follows.
      _holdLateContent(key, update, now);
      return;
    }
    _applyContentRevision(accountUserId, key, editDate, update);
  }

  /// Records one edit: [existing] keeps its state as the previous revision
  /// and takes the payload's content as the new one.
  void _applyContentRevision(
    int accountUserId,
    String key,
    int editDate,
    Map<String, dynamic> update,
  ) {
    // The mirror may have loaded or changed since the update was received.
    final existing = _byKey[key];
    if (existing == null || existing.state == MessageHistoryState.deleted) {
      // No kept copy, no revision: a diff without its base would float.
      return;
    }
    final chatId = existing.chatId;
    final messageId = existing.messageId;
    final content = update.obj('new_content');
    final newText = _messageText(content) ?? '';
    final newKind = _messageKindKey(content) ?? '';
    // A photo whose picture was replaced keeps its caption and its kind: the
    // only thing that moved is the file. Comparing just text/kind made those
    // edits invisible — the long-press menu then had no revision to show.
    final newFileId = _primaryMediaFileId(content);
    final mediaSwapped =
        newFileId > 0 &&
        existing.mediaFileId > 0 &&
        newFileId != existing.mediaFileId;
    if (newText == existing.text &&
        newKind == existing.kindKey &&
        !mediaSwapped) {
      return;
    }

    final now = _nowSeconds();
    final event = MessageHistoryEvent(
      at: now,
      oldText: existing.text,
      newText: newText,
      editDate: editDate,
      oldKindKey: existing.kindKey,
      oldMediaPath: existing.mediaPath,
    );
    // The copyWith writes the NEW text/kind now; the new revision's snapshot
    // (an edit can swap a photo for a document) is taken below and fills
    // only when the entry has none for that revision yet.
    _byKey[key] = existing.copyWith(
      text: newText,
      kindKey: newKind,
      mediaFileId: newFileId > 0 ? newFileId : existing.mediaFileId,
      events: [...existing.events, event],
    );
    notifyListeners();
    _schedulePersist();
    if ((newKind != existing.kindKey && newKind.isNotEmpty) || mediaSwapped) {
      _snapshotEditedMediaOf(accountUserId, chatId, messageId, content, key);
    }
  }

  /// The file id of the content's full-size picture or file, or 0.
  ///
  /// Mirrors [_mediaCandidates]' first non-poster pick: the largest photo
  /// size, or the video/document/animation file itself.
  static int _primaryMediaFileId(Map<String, dynamic>? content) {
    for (final candidate in _mediaCandidates(content)) {
      if (candidate.poster) continue;
      return jsonInt(candidate.file['id']) ?? 0;
    }
    return 0;
  }

  /// Snapshot the media of a just-recorded edit when the file is already on
  /// disk. Differently from the arrival snapshot, an edit's snapshot must
  /// NOT overwrite an existing path: only the first copy of a revision wins
  /// (every revision of one message shares the same per-message file name).
  void _snapshotEditedMediaOf(
    int accountUserId,
    int chatId,
    int messageId,
    Map<String, dynamic>? content,
    String entryKey,
  ) {
    final candidates = [
      for (final candidate in _mediaCandidates(content))
        if (!candidate.poster) candidate,
    ];
    if (candidates.isEmpty) return;
    final wrapped = <String, dynamic>{'chat_id': chatId, 'content': content};
    if (!_snapshotsEnabledFor(accountUserId, chatId, wrapped)) return;
    for (final candidate in candidates) {
      if (!_fileIsComplete(candidate.file)) continue;
      unawaited(_snapshotCandidate(entryKey, candidate, upgrade: false));
      break;
    }
  }

  /// updateDeleteMessages marks known, still-active entries as deleted.
  ///
  /// Only a PERMANENT deletion is history. The same update also reports
  /// messages that merely left TDLib's cache (`from_cache`, "can possibly be
  /// retrieved again") and messages that became inaccessible for this
  /// account (`is_permanent: false`) — both still exist on the server, and
  /// recording them as deletions made freshly opened chats sprout ghosts for
  /// perfectly normal messages. The transcript applies the same rule.
  ///
  /// A message that really comes back re-activates through
  /// [recordIncomingMessage] or [confirmAlive]. Deletions only ever touch the
  /// observing account's copy.
  void _recordDeletedMessages(int accountUserId, Map<String, dynamic> update) {
    if (!MessageHistorySettings.shared.recordDeleted) return;
    if (update.boolean('is_permanent') != true) return;
    final chatId = update.int64('chat_id');
    if (chatId == null) return;
    final ids = update.int64Array('message_ids') ?? const <int>[];
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var changed = false;
    for (final messageId in ids) {
      final key = '$accountUserId:$chatId:$messageId';
      final existing = _byKey[key];
      if (existing == null) continue;
      if (existing.state == MessageHistoryState.deleted) continue;
      _byKey[key] = existing.copyWith(
        state: MessageHistoryState.deleted,
        deletedAt: now,
      );
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
  }

  // ---------------------------------------------------------------------------
  // Exclusions, clearing
  // ---------------------------------------------------------------------------

  /// Stops the ACTIVE account from recording [chatId] and drops its kept
  /// copies of that chat — an excluded chat must have no mirror at all, not
  /// just a paused one. Other accounts' copies of the same chat are kept.
  void excludeChat(int chatId) => excludeChatFor(_activeAccountUserId, chatId);

  /// [excludeChat] for an explicit account (desktop utility window's chat
  /// info, pinned to one slot's account even when the primary window's
  /// active account differs).
  void excludeChatFor(int? accountUserId, int chatId) {
    if (!allowTelegramTosViolations) return;
    if (accountUserId == null) return;
    final excluded = _excludedChatsByAccount.putIfAbsent(
      accountUserId,
      () => <int>{},
    );
    if (!excluded.add(chatId)) return;
    _clearedChatAt['$accountUserId:$chatId'] = ++_scopeEpoch;
    _forgetPendingEdits(accountUserId, chatId: chatId);
    _byKey.removeWhere(
      (key, entry) =>
          entry.accountUserId == accountUserId && entry.chatId == chatId,
    );
    _forgetTrackedMediaWhere(
      (key) => key.startsWith('$accountUserId:$chatId:'),
    );
    _media().deleteScope(accountUserId, chatId);
    _persistExcludedChats(accountUserId);
    notifyListeners();
    _schedulePersist();
  }

  void includeChat(int chatId) => includeChatFor(_activeAccountUserId, chatId);

  /// [includeChat] for an explicit account (see [excludeChatFor]).
  void includeChatFor(int? accountUserId, int chatId) {
    if (!allowTelegramTosViolations) return;
    if (accountUserId == null) return;
    final excluded = _excludedChatsByAccount[accountUserId];
    if (excluded == null || !excluded.remove(chatId)) return;
    _persistExcludedChats(accountUserId);
    notifyListeners();
  }

  /// Removes the active account's kept copies of [chatId]; returns how many
  /// went away. Scope-stamps (account, chat) so an in-flight load cannot
  /// re-add the cleared rows from the mirror file afterwards, and queued
  /// updates for that chat that arrived before the clear are dropped after
  /// their identity resolves — without cancelling any other chat's or
  /// account's pending work.
  int clearChat(int chatId) {
    if (!allowTelegramTosViolations) return 0;
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) return 0;
    final keys = [
      for (final entry in _byKey.values)
        if (entry.accountUserId == accountUserId && entry.chatId == chatId)
          entry.key,
    ];
    for (final key in keys) {
      _byKey.remove(key);
      _forgetTrackedMedia(key);
    }
    _forgetPendingEdits(accountUserId, chatId: chatId);
    _clearedChatAt['$accountUserId:$chatId'] = ++_scopeEpoch;
    _media().deleteScope(accountUserId, chatId);
    notifyListeners();
    _schedulePersist();
    return keys.length;
  }

  /// Removes every kept copy of every account; returns how many went away.
  /// Deliberately global: "clear everything" must not leave invisible
  /// mirrors behind. Bumps the generation AND the scope epoch so pending
  /// queued updates and an in-flight load cannot resurrect any of it.
  int clearAll() {
    if (!allowTelegramTosViolations) return 0;
    final removed = _byKey.length;
    _byKey.clear();
    _pendingEditDates.clear();
    _lateContentUpdates.clear();
    _pendingAliveKeys.clear();
    _trackedMedia.clear();
    _entryMediaFileIds.clear();
    _channelChats.clear();
    _botChats.clear();
    _generation++;
    _clearedAllAt = ++_scopeEpoch;
    _media().deleteAll();
    notifyListeners();
    _schedulePersist();
    return removed;
  }

  /// Bytes the kept-message database occupies on disk: the mirror file plus
  /// every media snapshot. Nothing recorded yet reads as 0 — the settings
  /// row shows the number before the first message is kept.
  Future<int> databaseBytes() async {
    if (!allowTelegramTosViolations) return 0;
    var total = 0;
    try {
      final dir = fileDir ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) total += await file.length();
    } catch (_) {
      // An unresolvable support directory counts as an empty mirror.
    }
    final snapshotter = _media();
    await snapshotter.ensureDirResolved();
    total += snapshotter.usedBytes;
    return total;
  }

  /// Forgets an account entirely: its kept copies, its pending edit dates
  /// and its exclusion preference. Called when a slot is logged out or
  /// removed; account identity is known there, so nothing is guessed.
  /// Instead of the store-wide generation bump, the removal is SCOPE-stamped
  /// with the scope epoch: queued updates of THIS account that arrived
  /// before the removal are dropped once their identity resolves (pending
  /// work can never recreate history after logout/removal), while every
  /// other account's queued updates, loads and resolution continuations
  /// keep running untouched.
  void removeAccount(int accountUserId) {
    if (!allowTelegramTosViolations) return;
    var changed = false;
    final keys = [
      for (final entry in _byKey.values)
        if (entry.accountUserId == accountUserId) entry.key,
    ];
    for (final key in keys) {
      _byKey.remove(key);
      _forgetTrackedMedia(key);
    }
    if (keys.isNotEmpty) changed = true;
    _forgetPendingEdits(accountUserId);
    _media().deleteAccount(accountUserId);
    _channelChats.removeWhere((key, _) => key.startsWith('$accountUserId:'));
    _botChats.removeWhere((key, _) => key.startsWith('$accountUserId:'));
    if (_excludedChatsByAccount.remove(accountUserId) != null) changed = true;
    unawaited(_prefs?.remove('$_prefsKeyPrefix$accountUserId'));
    _removedAccountAt[accountUserId] = ++_scopeEpoch;
    if (_activeAccountUserId == accountUserId) {
      _activeAccountUserId = null;
      _activeAccountUserIdSource = null;
    }
    notifyListeners();
    if (changed) {
      _schedulePersist();
    }
  }

  /// Removes one kept entry (viewer row delete); also drops its snapshot.
  void deleteEntry(MessageHistoryEntry entry) {
    if (!allowTelegramTosViolations) return;
    if (_byKey.remove(entry.key) == null) return;
    _forgetTrackedMedia(entry.key);
    if (entry.mediaPath.isNotEmpty) {
      _media().deleteFile(entry.mediaPath);
    }
    notifyListeners();
    _schedulePersist();
  }

  void _persistExcludedChats(int accountUserId) {
    _prefs?.setStringList('$_prefsKeyPrefix$accountUserId', [
      for (final chatId
          in _excludedChatsByAccount[accountUserId] ?? const <int>{})
        '$chatId',
    ]);
  }

  // ---------------------------------------------------------------------------
  // Export / import — the whole mirror as one self-describing JSON file
  // (a portable document, no binary format).
  // ---------------------------------------------------------------------------

  static const exportVersion = 1;
  static const exportFormat = 'kept-history';

  /// Serializes the ACTIVE account's kept copies (entries, exclusions and
  /// the snapshot media as base64) into a portable JSON document. Media
  /// files are read once here; a missing file contributes nothing rather
  /// than failing the whole export.
  Future<Map<String, Object?>> exportAccount() async {
    if (!allowTelegramTosViolations) {
      throw StateError('History mirror is not compiled in');
    }
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) {
      throw StateError('No active account');
    }
    final entries =
        _byKey.values
            .where((entry) => entry.accountUserId == accountUserId)
            .toList()
          ..sort((a, b) {
            final byChat = a.chatId.compareTo(b.chatId);
            return byChat != 0 ? byChat : a.messageId.compareTo(b.messageId);
          });
    // Snapshot the media paths and exclusions BEFORE awaiting any file IO:
    // a message arriving mid-export must not change the exported set
    // half-way through, and a concurrent clear would leave the media map
    // inconsistent with the entries list.
    final mediaPaths = {
      for (final entry in entries)
        if (entry.mediaPath.isNotEmpty) entry.key: entry.mediaPath,
    };
    final excluded = Set<int>.of(
      _excludedChatsByAccount[accountUserId] ?? const <int>{},
    );
    final media = <String, String>{};
    final snapshotter = _media();
    for (final row in mediaPaths.entries) {
      final bytes = await snapshotter.readSnapshotBytes(row.value);
      if (bytes == null) continue;
      media[row.key] = base64Encode(bytes);
    }
    return {
      'format': exportFormat,
      'version': exportVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'account': accountUserId,
      'excluded': [for (final chatId in excluded) chatId],
      'entries': [for (final entry in entries) entry.toJson()],
      if (media.isNotEmpty) 'media': media,
    };
  }

  /// Restores an export into the store: replaces the importing account's
  /// mirror wholesale. In-flight writes are fenced by the scoped epoch the
  /// same way clearChat does, so pending updates can never resurrect the
  /// replaced state. Returns the number of restored entries.
  Future<int> importAccount(Map<String, Object?> document) async {
    if (!allowTelegramTosViolations) {
      throw const FormatException('History mirror is not compiled in');
    }
    if (document['format'] != exportFormat) {
      throw const FormatException('Not a kept-message history export');
    }
    final accountUserId = _activeAccountUserId;
    if (accountUserId == null) {
      throw StateError('No active account');
    }
    final exportedAccount = document['account'];
    if (exportedAccount is! int) {
      throw const FormatException('Export has no account');
    }
    final rawEntries = document['entries'];
    if (rawEntries is! List) {
      throw const FormatException('Export has no entries');
    }
    // Drop the account's current mirror first — an import replaces, not
    // merges — then restore row by row, re-keyed to THIS account.
    final keys = [
      for (final entry in _byKey.values)
        if (entry.accountUserId == accountUserId) entry.key,
    ];
    for (final key in keys) {
      _byKey.remove(key);
      _forgetTrackedMedia(key);
    }
    _forgetPendingEdits(accountUserId);
    _media().deleteAccount(accountUserId);
    final excluded = <int>{
      for (final raw
          in document['excluded'] is List
              ? document['excluded'] as List
              : const [])
        if (raw is int) raw,
    };
    _excludedChatsByAccount[accountUserId] = excluded;
    _persistExcludedChats(accountUserId);
    var restored = 0;
    for (final raw in rawEntries) {
      final entry = MessageHistoryEntry.fromJson(raw);
      if (entry == null) continue;
      // An imported exclusion means "no mirror for this chat" — its rows
      // must not come back either (they render nowhere and only bloat).
      if (excluded.contains(entry.chatId)) continue;
      _byKey['$accountUserId:${entry.chatId}:${entry.messageId}'] = entry
          .copyWith(
            accountUserId: accountUserId,
            // The row's snapshot path was written under the EXPORTING
            // account's prefix; the media loop rewrites the file under
            // THIS account and patches the row below, but only if the row
            // arrives without a stale path attached.
            mediaPath: '',
            // File ids and local cache paths are per account and per device;
            // keeping the exporter's would let a later download that happens
            // to reuse the id snapshot an unrelated file.
            mediaFileId: 0,
            mediaSourcePath: '',
            mediaPosterPath: '',
          );
      restored++;
    }
    final media = document['media'];
    if (media is Map) {
      final snapshotter = _media();
      for (final e in media.entries) {
        final data = e.value;
        if (data is! String) continue;
        final bytes = tryBase64Decode(data);
        if (bytes == null) continue;
        // Snapshot file names derive from (account, chat, message) — one
        // file per kept MESSAGE, never per revision: the latest revision's
        // media wins (the entry rows carry the matching mediaPath). The
        // file is re-keyed to the IMPORTING account so scope deletions can
        // reclaim it; the export key still names the row it belongs to.
        final restoredPath = await snapshotter.writeSnapshotBytes(
          e.key,
          bytes,
          accountUserIdOverride: accountUserId,
        );
        if (restoredPath != null) {
          final parts = e.key.split(':');
          if (parts.length != 3) continue;
          final chatId = int.tryParse(parts[1]);
          final messageId = int.tryParse(parts[2]);
          if (chatId == null || messageId == null) continue;
          final key = '$accountUserId:$chatId:$messageId';
          final entry = _byKey[key];
          if (entry != null && entry.mediaPath.isEmpty) {
            _byKey[key] = entry.copyWith(mediaPath: restoredPath);
          }
        }
      }
    }
    _trim();
    notifyListeners();
    _schedulePersist();
    return restored;
  }

  /// Permissive base64 decode for import payloads.
  static List<int>? tryBase64Decode(String data) {
    try {
      return base64Decode(data);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence — one JSON file for every account, batched, written
  // atomically via rename. Keys are account-scoped, so accounts share the
  // file without ever overwriting each other.
  // ---------------------------------------------------------------------------

  Future<void> ensureLoaded() async {
    if (!allowTelegramTosViolations) return;
    if (_loaded || _disposed) return;
    _loaded = true;
    final generation = _generation;
    try {
      final dir = fileDir ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      // The generation re-check drops the load when the store was wiped
      // (clearAll) or disposed while the file was being read: a fresh
      // on-disk batch must never resurrect the invalidated state. A SCOPED
      // invalidation (one account removed, one chat cleared) cancels only
      // its own disk rows below — every other account's and chat's rows
      // still load. Rows are judged against the scope epoch the FILE
      // reflects: a row whose scope was invalidated after the last persist
      // is stale on disk and is dropped even when the invalidation happened
      // before this load started.
      if (_disposed || _generation != generation) return;
      if (_clearedAllAt > _persistedScopeEpoch) return;
      if (decoded is! Map) return;
      final raw = decoded['entries'];
      if (raw is! List) return;
      for (final json in raw) {
        final entry = MessageHistoryEntry.fromJson(json);
        if (entry == null) continue;
        final removedAt = _removedAccountAt[entry.accountUserId];
        if (removedAt != null && removedAt > _persistedScopeEpoch) continue;
        final clearedAt =
            _clearedChatAt['${entry.accountUserId}:${entry.chatId}'];
        if (clearedAt != null && clearedAt > _persistedScopeEpoch) continue;
        // Exclusions live in prefs (written immediately) while entries live
        // in this file (debounced) — an excludeChat followed by a process
        // kill inside the persist window leaves the chat's stale rows here.
        // The exclusion is the newer intent, so its rows never load.
        if (_excludedChatsByAccount[entry.accountUserId]?.contains(
              entry.chatId,
            ) ??
            false) {
          continue;
        }
        final restored = _byKey.putIfAbsent(entry.key, () => entry);
        if (restored.mediaPath.isEmpty && restored.mediaFileId > 0) {
          _restoreTrackedMedia(restored);
        }
      }
      _trim();
    } catch (_) {
      // A corrupt mirror must never break the app; start over on next write.
    }
    if (_disposed || _generation != generation) return;
    notifyListeners();
  }

  /// Re-registers a loaded entry's media file so a download that finishes
  /// after a restart still becomes a snapshot; a file that is already on disk
  /// (its path survived in the entry) is copied right away.
  void _restoreTrackedMedia(MessageHistoryEntry entry) {
    final fileId = entry.mediaFileId;
    if (fileId <= 0) return;
    if (!_snapshotsEnabledFor(entry.accountUserId, entry.chatId, null)) return;
    final tracked = _trackedMedia.putIfAbsent(
      fileId,
      () =>
          _TrackedMediaFile(width: entry.mediaWidth, height: entry.mediaHeight),
    );
    tracked.entryKeys.add(entry.key);
    _entryMediaFileIds.putIfAbsent(entry.key, () => <int>{}).add(fileId);
    final sourcePath = entry.mediaSourcePath;
    if (sourcePath.isEmpty || !File(sourcePath).existsSync()) return;
    tracked.file ??= <String, dynamic>{
      '@type': 'file',
      'id': fileId,
      'local': <String, dynamic>{
        '@type': 'localFile',
        'path': sourcePath,
        'is_downloading_completed': true,
        'is_active_downloading': false,
      },
    };
    unawaited(_snapshotTrackedFile(fileId));
  }

  void _schedulePersist() {
    if (!allowTelegramTosViolations) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    if (!allowTelegramTosViolations || _disposed) return;
    if (_persisting) {
      _dirtyWhilePersisting = true;
      return;
    }
    _persisting = true;
    try {
      final dir = fileDir ?? await getApplicationSupportDirectory();
      final tmp = File('${dir.path}/$_fileName$_tmpSuffix');
      final batchScopeEpoch = _scopeEpoch;
      final batch = {
        'version': 2,
        'entries': [
          for (final entry in _byKey.values.skip(
            (_byKey.length - persistBatch).clamp(0, maxEntries),
          ))
            entry.toJson(),
        ],
      };
      await tmp.writeAsString(jsonEncode(batch), flush: true);
      final beforeRename = beforePersistRenameForTesting;
      if (beforeRename != null) await beforeRename();
      await tmp.rename('${dir.path}/$_fileName');
      // The file now reflects this exact invalidation state: loads may
      // trust every row in it again.
      _persistedScopeEpoch = batchScopeEpoch;
    } catch (_) {
      return;
    } finally {
      _persisting = false;
    }
    if (_dirtyWhilePersisting) {
      _dirtyWhilePersisting = false;
      _schedulePersist();
    }
  }

  @visibleForTesting
  Future<void> persistNowForTesting() => _persistNow();

  void _trim() {
    while (_byKey.length > maxEntries) {
      final key = _byKey.keys.first;
      _byKey.remove(key);
      _forgetTrackedMedia(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Message field extraction
  // ---------------------------------------------------------------------------

  /// The forum topic a raw TDLib `message` was posted in: 0 when it carries
  /// no explicit topic (ordinary chats, and a forum's General topic, which
  /// TDLib may leave unattributed). Only an explicit messageTopicForum
  /// counts, exactly like the transcript scoping rule
  /// (rawMessageBelongsToForumTopic); a bot topic chat always names its
  /// topic, so recording it needs no chat-id special case.
  static int _messageTopicId(Map<String, dynamic> message) {
    final topic = message.obj('topic_id');
    if (topic == null || topic.type != 'messageTopicForum') return 0;
    return topic.integer('forum_topic_id') ?? 0;
  }

  int? _senderId(Map<String, dynamic> message) {
    final sender = message.obj('sender_id');
    if (sender == null) return null;
    switch (sender.type) {
      case 'messageSenderUser':
        return sender.int64('user_id');
      case 'messageSenderChat':
        return sender.int64('chat_id');
    }
    return null;
  }

  /// Plain text of a [formattedText] object.
  static String? _formattedText(Map<String, dynamic>? formatted) =>
      formatted?.str('text');

  /// The message's text, or its caption for captioned media.
  static String? _messageText(Map<String, dynamic>? content) {
    if (content == null) return null;
    switch (content.type) {
      case 'messageText':
        return _formattedText(content.obj('text'));
      case 'messagePhoto':
      case 'messageVideo':
      case 'messageAnimation':
      case 'messageAudio':
      case 'messageDocument':
      case 'messageVoiceNote':
        return _formattedText(content.obj('caption')) ?? '';
    }
    return null;
  }

  /// Maps a TDLib content type onto the [AppStringKeys] suffix of a localized
  /// kind label; null for plain text. Stored as the bare suffix so the key
  /// names stay in one place (the viewer).
  static String? _messageKindKey(Map<String, dynamic>? content) {
    if (content == null) return null;
    switch (content.type) {
      case 'messagePhoto':
      case 'messageExpiredPhoto':
        return 'historyKindPhoto';
      case 'messageVideo':
      case 'messageExpiredVideo':
        return 'historyKindVideo';
      case 'messageVideoNote':
      case 'messageExpiredVideoNote':
        return 'historyKindVideoNote';
      case 'messageVoiceNote':
        return 'historyKindVoice';
      case 'messageAnimation':
        return 'historyKindAnimation';
      case 'messageSticker':
        return 'historyKindSticker';
      case 'messageDocument':
        return 'historyKindDocument';
      case 'messageAudio':
        return 'historyKindAudio';
      case 'messagePoll':
        return 'historyKindPoll';
      case 'messageLocation':
      case 'messageLiveLocation':
        return 'historyKindLocation';
      case 'messageContact':
        return 'historyKindContact';
      case 'messageDice':
        return 'historyKindDice';
    }
    return null;
  }
}
