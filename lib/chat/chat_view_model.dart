//
//  chat_view_model.dart
//
//  Conversation view model. Opens a chat, loads history, and keeps the message
//  list live by folding TDLib updates. For groups/channels it resolves each
//  incoming message's sender name + photo + role through a small cache so
//  bubbles can show "who said what". Port of the Swift `ChatViewModel`.
//

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/notifications/scope_notification_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_store.dart';
import '../channels/topic_list_actions.dart';
import '../chats/chat_delete_policy.dart';
import '../config/build_flags.dart';
import '../history/message_history_settings.dart';
import '../history/message_history_store.dart';
import '../notifications/notification_settings_payload.dart';
import '../settings/privacy_security/blocked_user_service.dart';
import '../settings/privacy_security/ghost_mode_controller.dart';
import '../settings/privacy_security/hidden_sender_store.dart';
import '../settings/privacy_security/keyword_blocker.dart';
import '../tdlib/forum_topic_index.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../tdlib/td_requests.dart';
import '../tdlib/td_user_index.dart';
import 'ai_translation/ai_reply_service.dart';
import 'ai_translation/telegram_ai_service.dart';
import 'ai_translation/unread_chat_summary_models.dart';
import 'chat_auto_scroll_policy.dart';
import 'chat_first_contact_info.dart';
import 'chat_message_merge.dart';
import 'chat_open_performance.dart';
import 'chat_send_failure.dart';
import 'chat_unread_progress.dart';
import 'composer/checklist_composer_view.dart';
import 'composer/checklist_service.dart';
import 'composer/message_send_options.dart';
import 'composer/outgoing_attachment.dart';
import 'composer/poll_composer_view.dart';
import 'composer/rich_message_source.dart';
import 'forum_topic_transcript.dart';
import 'forward_handoff.dart';
import 'links_search/link_preview_fixer.dart';
import 'messages/forward_markdown.dart';
import 'messages/forward_options.dart';
import 'messages/message_reaction_availability.dart';
import 'messages/message_text_quote.dart';
import 'messages/pangu_spacing.dart';
import 'messages/quick_reaction_choice.dart';
import 'protected_forward.dart';
import 'secret_chat_service.dart';
import 'sponsored_messages_cache.dart';
import 'stickers/gif_item.dart';
import 'stickers/sticker_item.dart';

part 'chat_view_model_actions.dart';
part 'chat_header_state_cache.dart';
part 'chat_view_model_header_topics.dart';
part 'chat_view_model_history_paging.dart';
part 'chat_view_model_sending.dart';
part 'chat_view_model_types.dart';
part 'chat_view_model_updates_merge.dart';

/// Slot → owning account identity bridge for the ghost transcript. The
/// chat view model cannot reach the provider tree, so main injects the
/// AccountStore lookup; tests inject their own mapping.
typedef AccountSummaryForSlot = AccountSummary? Function(int slot);

class ChatViewModel extends ChangeNotifier {
  static const int _maximumAiReplyContextMessages = 64;

  static const int _maximumAiReplySearchCharacters = 160;

  ChatViewModel({
    required this.chatId,
    required String title,
    required this.markReadOnOpen,
    this.initialMessageId,
    this.sessionAnchorMessageId,
    this.sessionFallbackOpenAtLatest,
    List<ChatMessage>? sessionMessages,
    bool sessionAnchoredHistory = false,
    ChatFirstContactInfo? sessionFirstContactInfo,
    ChatMessage? seedMessage,
    this.forumTopicId,
    this.historyStoreOverride,
  }) : _accountClientId = TdClient.shared.activeClientId,
       _accountSlot = TdClient.shared.activeSlot,
       peerTitle = title {
    // A pane rebuilt for another topic renders its rail from the shared index
    // on the first frame; loadForumTopics refreshes it moments later.
    final indexed = ForumTopicIndex.shared.topicsFor(_accountSlot, chatId);
    if (indexed.isNotEmpty) {
      forumTopics = [for (final entry in indexed) _optionFromIndex(entry)];
    }
    // Same chat, different topic: inherit the header facts the previous
    // transcript resolved (presence, member count, bot identity) so the
    // header paints at full height immediately and the pinned topic strip
    // does not shift when the async loads land.
    final inheritedHeader = ChatHeaderStateCache.read(_accountSlot, chatId);
    if (inheritedHeader != null) {
      // Topic-surface facts decide the tab chrome and the transcript sections
      // the first frame paints; without them a bot topic switch draws the
      // top strip once before getUser resolves the bot identity.
      isForum = inheritedHeader.isForum;
      hasForumTabs = inheritedHeader.hasForumTabs;
      supportsBotTopics = inheritedHeader.supportsBotTopics;
      botTopicsManageable = inheritedHeader.botTopicsManageable;
      peerOnline = inheritedHeader.peerOnline;
      peerStatusText = inheritedHeader.peerStatusText;
      peerIsBot = inheritedHeader.peerIsBot;
      memberCount = inheritedHeader.memberCount;
      isGroup = inheritedHeader.isGroup;
      isChannel = inheritedHeader.isChannel;
      isBotApiAccount = inheritedHeader.isBotApiAccount;
      botMenu = inheritedHeader.botMenu;
      botCommands = inheritedHeader.botCommands;
      botApiCanReadAllGroupMessages =
          inheritedHeader.botApiCanReadAllGroupMessages;
      botApiBotToBotAccessObserved =
          inheritedHeader.botApiBotToBotAccessObserved;
    }
    _historyAnchorMessageId = initialMessageId ?? sessionAnchorMessageId;
    if (sessionMessages != null && sessionMessages.isNotEmpty) {
      _allMessages = List<ChatMessage>.from(sessionMessages);
      messages = List<ChatMessage>.from(sessionMessages);
      _knownLatestMessageId = latestServerMessageId(sessionMessages);
      anchoredHistory = sessionAnchoredHistory;
      firstContactInfo = sessionFirstContactInfo;
      initialLoaded = true;
      _restoredFromSession = true;
    } else if (seedMessage != null) {
      _allMessages = [seedMessage];
      messages = [seedMessage];
    }
    _relabelChannelServiceMessages();
  }

  final int chatId;

  /// Store the ghost fold reads (tests inject one; production reads
  /// [MessageHistoryStore.shared]).
  final MessageHistoryStore? historyStoreOverride;

  /// When set, this transcript shows a single forum topic as an ordinary
  /// chat: history, search, drafts, sends and live updates are scoped to it.
  final int? forumTopicId;

  bool get isForumTopicTranscript => (forumTopicId ?? 0) != 0;

  void _onForumTopicIndexChanged() {
    // Only the topic list is live-indexed here: a transcript's own unread
    // state arrives through its chat-scoped updates, and topics of other
    // chats never move this view model.
    final indexed = ForumTopicIndex.shared.topicsFor(_accountSlot, chatId);
    if (indexed.isEmpty) return;
    final previous = forumTopics;
    // The index owns identity + counters; row-only fields (preview, pin,
    // closed, creator) stay with the option that already carries them.
    final byId = {for (final option in previous) option.id: option};
    var same = indexed.length == previous.length;
    final next = <ForumTopicOption>[];
    for (final entry in indexed) {
      final option =
          byId[entry.id]?._withIndex(entry) ?? _optionFromIndex(entry);
      if (same && !option.sameDisplay(previous[next.length])) same = false;
      next.add(option);
    }
    if (same) return;
    forumTopics = next;
    notifyListeners();
  }

  Map<String, dynamic>? get _forumTopicRef => isForumTopicTranscript
      ? {'@type': 'messageTopicForum', 'forum_topic_id': forumTopicId}
      : null;

  /// Whether this transcript is the mixed "All" view of a bot topic chat: a
  /// private chat with a topics-enabled bot, no General topic, no topic
  /// selected. Nothing can be posted there as-is — every send has to start or
  /// join a topic.
  bool get _inBotTopicAllView =>
      supportsBotTopics && !isForum && !isForumTopicTranscript;

  /// Whether [raw] (a TDLib `message`) belongs to this transcript.
  ///
  /// In a bot topic chat there is no General topic, so an unattributed
  /// message must not fall back to it (see
  /// [rawMessageBelongsToForumTopic]).
  bool _belongsToTranscript(Map<String, dynamic> raw) =>
      !isForumTopicTranscript ||
      rawMessageBelongsToForumTopic(
        raw,
        forumTopicId!,
        isGeneralFallbackAllowed: isForum,
      );

  /// Rewrites a chat-wide history request into its topic-scoped equivalent.
  Map<String, dynamic> _scopedHistoryRequest(Map<String, dynamic> request) =>
      isForumTopicTranscript
      ? forumTopicHistoryRequest(request, forumTopicId!)
      : request;

  /// The topic's display name once loaded; empty for ordinary transcripts.
  String forumTopicName = '';

  Future<Map<String, dynamic>> _queryHistory(
    Map<String, dynamic> request,
  ) async {
    final scoped = _scopedHistoryRequest(request);
    if (scoped.type != 'getForumTopicHistory') return _client.query(scoped);
    try {
      return await _client.query(scoped);
    } catch (_) {
      return _client.query(forumTopicThreadHistoryRequest(scoped));
    }
  }

  Future<Map<String, dynamic>?> _loadForumTopic() async {
    try {
      final topic = await _client.query({
        '@type': 'getForumTopic',
        'chat_id': chatId,
        'forum_topic_id': forumTopicId,
      });
      forumTopicName = topic.obj('info')?.str('name') ?? forumTopicName;
      return topic;
    } catch (_) {
      return null;
    }
  }

  final int? initialMessageId;

  final int? sessionAnchorMessageId;

  final bool? sessionFallbackOpenAtLatest;

  final bool markReadOnOpen;

  /// 盘古之白 for outgoing text, mirrored from ThemeController by the view that
  /// owns this model: the model itself has no theme access.
  bool panguOnSend = false;

  /// 盘古之白 for edits, which rewrite a message the other side already read.
  bool panguOnEdit = false;

  int? _historyAnchorMessageId;

  int? get historyAnchorMessageId => _historyAnchorMessageId;

  List<ChatMessage> messages = [];

  List<ChatMessage> _allMessages = [];

  // Lookup indexes over the two transcript lists, filled by the single pass in
  // _applyKeywordFilter. Folding one update used to linear-scan the whole
  // transcript several times (id lookups, sender patches); at a few thousand
  // loaded messages that scanning dominated the incoming-update path.
  final Map<int, ChatMessage> _messagesById = {};

  final Map<int, ChatMessage> _allMessagesById = {};

  final Map<int, List<ChatMessage>> _messagesBySenderId = {};

  final Map<int, ValueNotifier<int>> _messageRevisionNotifiers = {};

  final ValueNotifier<int> _headerRevisionNotifier = ValueNotifier<int>(0);

  int _transcriptScanVisitsForTesting = 0;

  bool _messageIndexesDirty = true;

  // A pending send makes compareChatMessagesChronologically non-total, so the
  // order-preserving shortcuts below only run while there are none.
  int _pendingMessageCount = 0;

  String peerTitle;

  TdFileRef? peerPhoto;

  ChatFirstContactInfo? firstContactInfo;

  ChatKind? chatKind;

  bool isGroup = false;

  int memberCount = 0;

  int? peerUserId;

  // private chat → call target
  int? peerBasicGroupId;

  int? peerSupergroupId;

  String meName = AppStrings.t(AppStringKeys.chatMeLabel);

  int? meId;

  Set<String> meUsernames = const <String>{};

  TdFileRef? mePhoto;

  String draft = '';

  String _draftFormattedText = '';

  List<Map<String, dynamic>> _draftFormattedEntities = const [];

  final List<_DraftMention> _draftMentions = [];

  ChatMessage? _replyTo;

  MessageTextQuote? _replyQuote;

  /// The chat the pending reply targets. Null means the reply lives in this
  /// transcript's own chat; a different id marks a cross-chat reply, which
  /// TDLib only accepts as `inputMessageReplyToExternalMessage`.
  int? _replyToChatId;

  /// Bumped every time the pending reply changes. A send stamps the
  /// revision it captured; when it completes, it only consumes the reply
  /// if the user hasn't picked a different one in the meantime.
  int _replyRevision = 0;

  ChatMessage? get replyTo => _replyTo;

  /// The chat the pending reply addresses, when it is not this chat.
  int? get replyToChatId => _replyToChatId;

  set replyTo(ChatMessage? message) {
    _replyTo = message;
    _replyQuote = null;
    _replyToChatId = null;
    _replyRevision++;
  }

  MessageTextQuote? get replyQuote => _replyQuote;

  /// The forum-topic destination for inline-bot and gif sends when this
  /// transcript is scoped to one topic.
  Map<String, dynamic>? get forumTopicSendRef => _forumTopicRef;

  Map<String, dynamic>? get replyToInput => replyTo == null
      ? null
      : _replyToChatId == null
      ? {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyTo!.id,
          if (!isSecretChat && _replyQuote != null)
            'quote': _replyQuote!.toInputJson(),
        }
      : {
          // A cross-chat reply addresses a message outside this transcript;
          // the same-chat form would point at an unrelated local id.
          '@type': 'inputMessageReplyToExternalMessage',
          'chat_id': _replyToChatId,
          'message_id': replyTo!.id,
          if (!isSecretChat && _replyQuote != null)
            'quote': _replyQuote!.toInputJson(),
        };

  /// Panel sends (sticker, GIF, voice note, poll, …) can't attach the reply
  /// anchor inside their content payloads, so they route through this helper:
  /// it stamps the pending reply onto the request and returns the revision
  /// the stamp was taken at. The send later consumes the reply only when
  /// that revision is still current, so completing an older send never
  /// clears a reply the user selected meanwhile. Failed sends keep the
  /// reply for retry, mirroring the text path's contract.
  ({Map<String, dynamic> request, int revision}) _withReplyAnchor(
    Map<String, dynamic> request,
  ) {
    final revision = _replyRevision;
    if (replyTo != null) {
      request['reply_to'] = replyToInput;
    }
    return (request: request, revision: revision);
  }

  /// Consumes the pending reply only if it is still the one [revision]
  /// stamped. A newer selection survives; a consumed anchor reports false.
  bool _consumeReplyAnchorIfCurrent(int revision) {
    if (replyTo == null) return false;
    if (revision != _replyRevision) return false;
    replyTo = null;
    notifyListeners();
    return true;
  }

  ChatMessage? editingMessage;

  String? _draftBeforeEditing;

  String _formattedDraftBeforeEditing = '';

  List<Map<String, dynamic>> _entitiesBeforeEditing = const [];

  List<_DraftMention> _mentionsBeforeEditing = const [];

  ChatMessage? _replyBeforeEditing;

  MessageTextQuote? _replyQuoteBeforeEditing;

  List<MessageSenderOption> availableMessageSenders = const [];

  MessageSenderOption? selectedMessageSender;

  Map<String, dynamic>? _messageSenderFromChat;

  // Live header state.
  bool peerOnline = false;

  /// Private-chat peer's avatar-dot presence; groups use each sender's own.
  AvatarPresence peerPresence = AvatarPresence.none;

  String peerStatusText = '';

  int lastReadOutboxId = 0;

  // outgoing messages with id <= this are read
  int lastReadInboxId = 0;

  // incoming messages with id <= this are read
  int unreadCount = 0;

  // unread incoming messages on entry (for the divider)
  UnreadChatRangeSnapshot? unreadSummarySnapshot;

  bool _didCaptureUnreadSummaryRange = false;

  int unreadMentionCount = 0;

  int unreadReactionCount = 0;

  bool isMarkedUnread = false;

  // manual unread marker on the chat row
  bool initialLoaded = false;

  // first history page (+ unread boundary) is in
  bool anchoredHistory = false;

  // transcript is centered on an arbitrary target

  // 群公告 / pinned message shown in a bar below the header.
  ChatMessage? pinnedMessage;

  List<ChatMessage> pinnedMessages = const [];

  int pinnedMessageIndex = 0;

  bool pinnedDismissed = false;

  /// The pinned ids the bar was closed over, remembered on this device for
  /// this account and chat (and topic); null while the bar is not closed.
  Set<int>? _pinnedDismissedIds;

  Future<void>? _pinnedDismissalLoad;

  String? _pinnedDismissalKey;

  bool _pinnedDismissalChanged = false;

  // Membership / send permission. Defaults assume a normal, joined, sendable
  // chat; refined in _loadChatHeader once the chat type + member status load.
  bool canSendMessages = true;

  // composer enabled
  bool canSendVoiceNotes = true;

  bool isMember = true;

  // gates 退出; false → join affordance
  bool canJoin = false;

  // not a member but joinable (public super/channel/left)
  bool joinByRequest = false;

  // joining needs approval → "申请加入"
  bool joinRequested = false;

  // a join request was sent (awaiting approval)
  bool isChannel = false;

  // broadcast channel (members can't post)
  bool isMessageBubbleRepository = false;

  /// Parses one TDLib message with this chat's group/channel label context.
  ChatMessage? _parseMessage(Map<String, dynamic> raw) =>
      TDParse.message(raw, isChannel: isChannel);

  /// Re-labels service messages that were parsed before [isChannel] resolved.
  /// A channel opened from a cold cache can hydrate its first history page in
  /// parallel with getChat/getSupergroup; those banners must not keep group
  /// wording once the type is known.
  void _relabelChannelServiceMessages() {
    if (!isChannel) return;
    final seen = <ChatMessage>{};
    for (final message in [..._allMessages, ...messages, ...pinnedMessages]) {
      if (!seen.add(message)) continue;
      final text = TDParse.channelServiceText(message);
      if (text != null) message.text = text;
    }
    // Join/leave/boost banners carry an actor name resolved asynchronously.
    // Re-run that resolution so a banner personalised before the channel type
    // resolved is rebuilt with channel wording instead of being left as-is.
    _resolveServiceUsersIfNeeded([
      for (final message in _allMessages)
        if (message.isService) message,
    ]);
  }

  bool hasLinkedDiscussion = false;

  /// Chat id of the chat linked to this one — a channel's discussion group or
  /// a group's channel — 0 when there is none. [hasLinkedDiscussion] stays the
  /// boolean the transcript reads; this id is what the channel bottom panel
  /// and the header menu open.
  int linkedDiscussionChatId = 0;

  /// Chat id of the channel's direct-messages group (`market`-style 私聊),
  /// 0 when the channel does not offer one.
  int directMessagesChatId = 0;

  bool get hasDirectMessagesGroup => directMessagesChatId != 0;

  /// Whether the current account may delete its own copy of this chat's
  /// history — the header menu's Clear history gate.
  bool canClearHistory = false;

  /// Whether the current account administers this group or channel.
  bool canManageGroup = false;

  /// Whether the current account owns the group/channel. The owner cannot
  /// leave it, so the menu hides Leave for them.
  bool isChatCreator = false;

  /// Call availability for a private chat (TDLib userFullInfo `can_be_called`
  /// and `supports_video_calls`).
  bool canCallPeer = false;
  bool canVideoCallPeer = false;

  bool isDirectMessagesGroup = false;

  bool isAdministeredDirectMessagesGroup = false;

  bool isMuted = false;

  // notifications muted (channel subscribers get a toggle)
  bool canDeleteMessagesBySender = false;

  String sendDisabledReason = '';

  // shown in the disabled composer bar
  bool isPeerRestricted = false;

  bool isPeerPornographicRestricted = false;

  String peerRestrictionText = '';

  bool hasProtectedContent = false;

  /// The plan from the most recent protected-content copy forward, for the
  /// UI's partial-migration toast. Null until a copy forward has run.
  ProtectedForwardPlan? protectedForwardLastPlan;

  bool _chatCanSend = true; // chat-wide default can_send_basic_messages

  /// Topic moderation rights for forum chats. Creating needs the
  /// can_manage_topics administrator right or the can_create_topics member
  /// right; in a chat with a topics bot it follows the bot's own
  /// `allows_users_to_create_topics` flag (tdesktop's `canCreateTopic`), which
  /// no supergroup right ever answers. Pinning/editing/closing need
  /// can_manage_topics; deleting needs can_delete_messages unless the user
  /// created the topic.
  bool _chatCanCreateTopics = false;

  bool canManageTopics = false;

  bool canDeleteForumTopics = false;

  bool get canCreateForumTopics =>
      _chatCanCreateTopics || canManageTopics || botTopicsManageable;

  /// Per-topic creator deletion eligibility, verified against the topic's
  /// actual message history. TDLib's deleteForumTopic allows a non-admin
  /// creator to delete only while the topic holds at most 11 messages and
  /// none of them are from other users; creator identity alone is not
  /// sufficient. Cleared on topic traffic so the next menu open re-probes.
  final Map<int, bool> _creatorDeletableTopicIds = {};

  /// Whether this account may delete [topic]. can_manage_topics grants
  /// management, not deletion; only can_delete_messages does. Otherwise the
  /// topic's creator may delete it while it holds at most 11 messages and
  /// none from other users (probed, see [ensureTopicCreatorDeletable]).
  ///
  /// In a chat with a topics bot Telegram offers Delete on every topic —
  /// tdesktop's `ForumTopic::canDelete` returns true for bot peers — and
  /// leaves the check to the server, which only refuses topics the user
  /// didn't start. The history probe must not gate that: bot replies count
  /// as other users' messages and would hide the row for every real topic.
  bool canDeleteTopic(ForumTopicOption topic) {
    if (topic.isGeneral) return false;
    if (canDeleteForumTopics) return true;
    if (isBotTopicChat) return true;
    return creatorOfTopic(topic) &&
        (_creatorDeletableTopicIds[topic.id] ?? false);
  }

  /// Whether [topic] was created by this account.
  bool creatorOfTopic(ForumTopicOption topic) =>
      meId != null && topic.creatorId == meId;

  /// Whether this account may close or reopen [topic]: can_manage_topics, or
  /// the topic's own creator (TDLib's carve-out). A chat with a bot has no
  /// close call at all — TDLib's toggleForumTopicIsClosed is supergroup-only.
  bool canCloseTopic(ForumTopicOption topic) =>
      isForum && !topic.isGeneral && (canManageTopics || creatorOfTopic(topic));

  /// Probes whether the creator carve-out applies to [topicId]: at most 11
  /// messages and none from another user. The 12th message proves the limit
  /// is exceeded without paging further. Supergroups only: a chat with a
  /// topics bot offers Delete without this probe (see [canDeleteTopic]).
  Future<bool> ensureTopicCreatorDeletable(int topicId) async {
    if (!isForum || topicId == generalForumTopicId) return false;
    if (_creatorDeletableTopicIds.containsKey(topicId)) {
      return _creatorDeletableTopicIds[topicId]!;
    }
    bool eligible = false;
    try {
      final response = await _topicAccountQuery({
        '@type': 'getForumTopicHistory',
        'chat_id': chatId,
        'forum_topic_id': topicId,
        'from_message_id': 0,
        'offset': 0,
        'limit': 12,
      });
      final messages = response.objects('messages') ?? const [];
      eligible =
          messages.length <= 11 &&
          messages.every((raw) {
            if (raw.boolean('is_outgoing') ?? false) return true;
            final sender = raw.obj('sender_id');
            return sender?.type == 'messageSenderUser' &&
                sender?.int64('user_id') == meId;
          });
    } catch (_) {
      eligible = false;
    }
    _creatorDeletableTopicIds[topicId] = eligible;
    return eligible;
  }

  /// Drops the probed creator carve-out for any topic new traffic reached, so
  /// a topic that gained a 12th message or another user's message stops
  /// offering Delete on the next menu open.
  void _invalidateCreatorDeletionForTopic(int topicId) {
    if (_creatorDeletableTopicIds.remove(topicId) != null) {
      notifyListeners();
    }
  }

  bool peerIsBot = false;

  bool isBotApiAccount = false;

  bool botApiCanReadAllGroupMessages = false;

  bool botApiBotToBotAccessObserved = false;

  bool isSecretChat = false;

  int businessBotUserId = 0;

  String businessBotManageUrl = '';

  bool businessBotPaused = false;

  bool businessBotCanReply = false;

  int? _secretChatId;

  bool botStartSent = false;

  BotMenuInfo? botMenu;

  List<BotCommandOption> botCommands = const [];

  bool isForum = false;

  bool hasForumTabs = false;

  bool supportsBotTopics = false;

  /// True when the peer bot lets users manage its topics
  /// (`userTypeBot.allows_users_to_create_topics`). Pin, edit and delete in a
  /// chat with a bot need no administrator rights there, so the topic menus
  /// must not gate those rows on [canManageTopics] alone.
  bool botTopicsManageable = false;
  bool _forumTopicsLoaded = false;

  /// Pin/edit rights for the topic surfaces: forum administrators
  /// ([canManageTopics]) or a bot topic chat whose bot allows management.
  bool get canPinAndEditTopics => canManageTopics || botTopicsManageable;

  /// Whether the tab strip's pinned block can be rearranged: the same rights
  /// that allow pinning, plus at least two pinned topics to swap.
  bool get canReorderPinnedTopics =>
      canPinAndEditTopics &&
      forumTopics.where((topic) => topic.isPinned).length > 1;

  bool get supportsTopics => isForum || supportsBotTopics;

  /// A private chat with a topics-enabled bot: no supergroup rights exist
  /// there, so topic actions follow the bot's own capabilities.
  bool get isBotTopicChat => supportsBotTopics && !isForum;

  bool forumTopicsLoading = false;

  /// Topic info requests in flight for topics discovered through live traffic.
  final Set<int> _pendingForumTopicInfoRequests = {};

  List<ForumTopicOption> forumTopics = const [];

  /// Resolved display names for topic-preview senders, kept across reloads so
  /// the row's "Alice: …" prefix survives a getForumTopics refresh.
  final Map<int, String> _topicSenderNames = {};

  /// Topic id → its last message's sender id, for late sender resolution.
  final Map<int, int> _topicRowSenderIds = {};

  int messageAutoDeleteTime = 0;

  int paidMessageStarCount = 0;

  /// Non-null once [loadForumTopics] registered the shared-index listener.
  /// ChangeNotifier.addListener returns void, so this only records whether
  /// the one-per-model registration happened (refreshes reuse it).
  bool _forumTopicIndexListening = false;

  bool peerRequiresPremiumOrContact = false;

  bool peerIsUnavailable = false;

  /// Loaded for channels and bot chats, but not yet rendered in the transcript.
  SponsoredMessagesSnapshot? sponsoredMessages;

  final TdClient _client = TdClient.shared;

  final int _accountClientId;

  final int _accountSlot;

  /// The account slot whose ids this transcript's data is scoped to.
  int get accountSlot => _accountSlot;

  /// The pinned TDLib client id the current transcript's messages belong to.
  /// Forward handoffs stamp it so the target chat can pin its forward queries
  /// to the account that supplied the source ids.
  int get accountClientIdForForwarding => _accountClientId;

  int _groupBotCommandsGeneration = 0;

  Future<Set<String>>? _aiReplyBlockedSenderKeysFuture;

  int _aiReplyBlockedSenderRevision = 0;

  late final TelegramAiService telegramAi = TelegramAiService(client: _client);

  TelegramAiCapabilities? aiCapabilities;

  static final SponsoredMessagesCache _sponsoredMessagesCache =
      SponsoredMessagesCache();

  StreamSubscription? _sub;

  final ChatLiveMessageBuffer _liveIncomingMessages = ChatLiveMessageBuffer();

  /// Own messages TDLib pushed into the open transcript (a local echo of a
  /// send from this device, or the same account sending from another one).
  /// They are not unread traffic, so they ride their own buffer — the
  /// transcript only uses them to play the same entrance incoming messages
  /// get.
  final ChatLiveMessageBuffer _liveOutgoingMessages = ChatLiveMessageBuffer();

  bool _isLoadingOlder = false;

  bool _isLoadingNewer = false;

  final Set<int> _newerHistoryDeletedMessageIds = {};

  bool _hasOlderHistory = true;

  int? _pendingScrollToId;

  int? _lastForcedReadMessageId;

  bool _markReadInFlight = false;

  bool _restoredFromSession = false;

  bool _chatReadStateLoaded = false;

  bool get chatReadStateLoaded => _chatReadStateLoaded;

  int _chatReadStateRevision = 0;

  int get chatReadStateRevision => _chatReadStateRevision;

  int _chatReadInboxRevision = 0;

  bool _historyReachesLatest = false;

  bool get historyReachesLatest => _historyReachesLatest;

  int _knownLatestMessageId = 0;

  int get knownLatestMessageId => _knownLatestMessageId;

  bool _latestHistoryLoadInFlight = false;

  final Map<int, ChatMessage> _latestHistoryLiveArrivals = {};

  final Set<int> _latestHistoryDeletedMessageIds = {};

  bool _latestHistoryLoadInvalidated = false;

  int _historyWindowGeneration = 0;

  int _historyWindowRevision = 0;

  int get historyWindowRevision => _historyWindowRevision;

  int _historyWindowInvalidationRevision = 0;

  int get historyWindowInvalidationRevision =>
      _historyWindowInvalidationRevision;

  final Set<int> _blockedReadIds = {};

  final Set<int> _messagePropertiesLoading = {};

  final Map<int, bool> _speechRecognitionEligibility = {};

  final Set<int> _locallyViewedMentionIds = {};

  final Set<int> _locallyViewedReactionIds = {};

  final Set<int> _blockedSenderIds = {};

  final Set<int> _discardedPendingMessageIds = {};

  final Set<int> _settledPendingMessageIds = {};

  final Set<int> _acknowledgedPendingMessageIds = {};

  final Map<int, Completer<void>> _messageSendWaiters = {};

  final Map<int, _MessageSendResult> _recentMessageSendResults = {};

  ChatSendFailure? _pendingSendFailure;

  String? _lastSendFailureKey;

  int _lastSendFailureAtMilliseconds = 0;

  Future<void>? _privateMessageInfoLoad;

  int? _privateMessageInfoUserId;

  bool _privateMessageInfoLoaded = false;

  // Transient chat actions: sender ids currently acting, auto-cleared shortly.
  final Map<int, _ChatActionInfo> _chatActions = {};

  Timer? _typingTimer;

  Timer? _draftSaveTimer;

  Timer? _coalescedNotifyTimer;

  String? _lastSavedDraftText;

  /// Header title: profile shows the member count in parentheses after a group name.
  String get headerTitle =>
      (isGroup && memberCount > 0) ? '$peerTitle($memberCount)' : peerTitle;

  /// Subtitle under the title: online/last-seen plus transient chat actions.
  /// Group member count lives in the title, not here.
  String get subtitle {
    final base = isGroup || peerIsBot
        ? ''
        : (peerOnline
              ? AppStrings.t(AppStringKeys.presenceOnline)
              : peerStatusText);
    final action = _chatActionSubtitle;
    if (base.isEmpty) return action;
    if (action.isEmpty) return base;
    return '$base · $action';
  }

  /// The header title for this transcript: the topic's name when a forum topic
  /// is shown as an ordinary chat, otherwise the peer title.
  String get displayTitle =>
      forumTopicName.trim().isNotEmpty ? forumTopicName.trim() : peerTitle;

  bool get hasActiveChatAction => _chatActions.isNotEmpty;

  bool isRead(ChatMessage m) => isOutgoingServerMessageRead(
    message: m,
    lastReadOutboxId: lastReadOutboxId,
  );

  bool get canChooseMessageSender => availableMessageSenders.length > 1;

  bool get canForwardContent => !hasProtectedContent;

  bool get canLoadOlder =>
      !_isLoadingOlder &&
      !_latestHistoryLoadInFlight &&
      _allMessages.isNotEmpty &&
      _hasOlderHistory;

  bool get isLoadingOlder => _isLoadingOlder;

  bool get canLoadNewer =>
      !_chatOpenWorkIsStale &&
      !_isLoadingNewer &&
      !_latestHistoryLoadInFlight &&
      !_historyReachesLatest &&
      latestServerMessageId(_allMessages) > 0;

  bool get isLoadingLatest => _latestHistoryLoadInFlight;

  bool get hasOlderHistory => _hasOlderHistory;

  int get _oldestServerMessageId {
    for (final message in _allMessages) {
      if (!isPendingChatMessage(message) && message.id > 0) return message.id;
    }
    return 0;
  }

  bool get requiresPaidMessage => paidMessageStarCount > 0;

  bool get canUseAiComposition =>
      aiCapabilities?.compositionSupported == true && !isSecretChat;

  bool get canUseAiSummary => aiCapabilities?.summarySupported == true;

  bool get canUseSpeechRecognition =>
      aiCapabilities?.transcriptionSupported == true;

  bool get canSendWhenOnline => !isGroup && !peerIsBot;

  /// The chat is the account's own Saved Messages.
  bool get isSavedMessages => peerUserId != null && peerUserId == meId;

  /// Telegram accepts View Once and self-destructing media only in one-on-one
  /// chats with another person: not groups, channels, bots, Saved Messages or
  /// secret chats, which have their own message timer.
  bool get canSendSelfDestructingMedia =>
      canSendWhenOnline && !isSavedMessages && !isSecretChat;

  bool get showBotApiPrivacyWarning =>
      isBotApiAccount &&
      isGroup &&
      !isChannel &&
      !botApiCanReadAllGroupMessages;

  bool get showBotApiBotToBotWarning =>
      isBotApiAccount && isGroup && !isChannel && !botApiBotToBotAccessObserved;

  bool get showBotApiAccessWarning =>
      showBotApiPrivacyWarning || showBotApiBotToBotWarning;

  List<AvailableMessageEffect> availableMessageEffects = const [];

  MessageSendConfiguration? _nextSendConfiguration;

  /// A topic creation a bot-topic "All" send is awaiting, shared by every
  /// concurrent send so two quick messages land in the same new topic instead
  /// of opening two (the reference client serialises them the same way).
  Future<int?>? _botTopicCreation;

  /// The topic this view model started for the "All" view's sends. A rich
  /// document arrives as several segments and two quick taps are two sends;
  /// all of them belong to the one conversation the first send opened, so the
  /// burst id outlives the creation request.
  int? _botTopicBurstId;

  /// The topic a send from a bot topic chat's "All" view just started, until
  /// the transcript host consumes it and opens that topic.
  int? _pendingBotTopicOpen;

  String get inputPlaceholder =>
      AppStrings.t(AppStringKeys.chatMessageInputPlaceholder);

  final Map<int, _SenderInfo> _senderCache = {};

  final Set<int> _resolvingSenders = {};

  final Set<int> _resolvedSenderDetails = {};

  bool _isDisposed = false;

  bool get _chatOpenWorkIsStale => chatOpenWorkIsStale(
    disposed: _isDisposed,
    openingClientId: _accountClientId,
    openingAccountSlot: _accountSlot,
    activeClientId: _client.activeClientId,
    activeAccountSlot: _client.activeSlot,
  );

  int _composerRevision = 0;

  int _fullViewRevision = 0;

  int _composerFocusTick = 0;
  int _composerDismissTick = 0;

  /// Bumped by every notification except the handful proven not to touch
  /// anything the composer renders, so the input bar can skip those rebuilds.
  /// Bumping is the default: a path that forgets to opt out stays correct.
  int get composerRevision => _composerRevision;

  /// Changes only when a notification can affect ChatView's shell, transcript
  /// boundaries, scrolling, or overlays. Header-only and in-place bubble
  /// updates keep this stable so ChatView can skip its O(n) synchronization.
  int get fullViewRevision => _fullViewRevision;

  ValueListenable<int> get headerRevisionListenable => _headerRevisionNotifier;

  /// Bumped when a gesture outside the composer asks for the caret. The reply
  /// target itself travels with [setReply]; this only says "and start typing".
  int get composerFocusTick => _composerFocusTick;

  /// Hands the composer the caret without touching its draft or revision.
  void requestComposerFocus() {
    if (_isDisposed) return;
    _composerFocusTick++;
    super.notifyListeners();
  }

  /// Bumped when the user drags the transcript, so the composer can collapse
  /// its open panels the same way the OS keyboard folds on drag.
  int get composerDismissTick => _composerDismissTick;

  ValueListenable<int> messageRevisionListenable(int messageId) =>
      _messageRevisionNotifiers.putIfAbsent(
        messageId,
        () => ValueNotifier<int>(0),
      );

  int get transcriptScanVisitsForTesting => _transcriptScanVisitsForTesting;

  int get messageRevisionNotifierCountForTesting =>
      _messageRevisionNotifiers.length;

  void resetTranscriptScanVisitsForTesting() {
    _transcriptScanVisitsForTesting = 0;
  }

  void primeMessageIndexesForTesting() {
    _ensureMessageIndexes();
  }

  bool _recordTranscriptScanVisitForTesting() {
    _transcriptScanVisitsForTesting++;
    return true;
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    _composerRevision++;
    _fullViewRevision++;
    super.notifyListeners();
  }

  /// Notifies without bumping [composerRevision]. Only for state no composer
  /// widget reads — the typing subtitle and the peer's online status, both of
  /// which belong to the header.
  void _notifyComposerNeutral() {
    if (_isDisposed) return;
    _headerRevisionNotifier.value++;
    super.notifyListeners();
  }

  /// Rebuilds only materialized bubbles for [messageIds]. The regular model
  /// notification is deliberately retained: ChatInputBar uses it to invalidate
  /// AI context and preserves its focused revision-rebuild policy.
  void _notifyLocalizedMessages(Iterable<int> messageIds) {
    if (_isDisposed) return;
    if (!_bumpMaterializedMessageRevisions(messageIds)) return;
    _composerRevision++;
    super.notifyListeners();
  }

  /// Refreshes materialized bubbles while retaining ChatView's full sync for
  /// cross-message and shell dependencies such as translation and overlays.
  void _notifyMessagesWithFullViewSync(Iterable<int> messageIds) {
    if (_isDisposed) return;
    if (!_bumpMaterializedMessageRevisions(messageIds)) return;
    notifyListeners();
  }

  bool _bumpMaterializedMessageRevisions(Iterable<int> messageIds) {
    var changed = false;
    for (final messageId in messageIds.toSet()) {
      final notifier = _messageRevisionNotifiers[messageId];
      if (notifier != null) notifier.value++;
      changed = true;
    }
    return changed;
  }

  int? consumePendingScrollToId() {
    final id = _pendingScrollToId;
    _pendingScrollToId = null;
    return id;
  }

  List<int> consumeLiveIncomingMessageIds() => _liveIncomingMessages.takeAll();

  List<int> consumeLiveOutgoingMessageIds() => _liveOutgoingMessages.takeAll();

  ChatSendFailure? consumeSendFailure() {
    final failure = _pendingSendFailure;
    _pendingSendFailure = null;
    return failure;
  }

  void useNextSendConfiguration(MessageSendConfiguration configuration) {
    _nextSendConfiguration = configuration;
  }

  Map<String, dynamic> _withPaidMessageOptions(
    Map<String, dynamic> request, {
    MessageSendConfiguration? sendConfiguration,
    bool consumePendingConfiguration = true,
  }) {
    final count = paidMessageStarCount;
    final pending = sendConfiguration ?? _nextSendConfiguration;
    if (consumePendingConfiguration && sendConfiguration == null) {
      _nextSendConfiguration = null;
    }
    final topic = _forumTopicRef;
    if (topic != null && request.int64('chat_id') == chatId) {
      request.remove('message_thread_id');
      request['topic_id'] = topic;
    }
    final existing = request.obj('options') ?? const <String, dynamic>{};
    if (count > 0 || pending != null || existing.isNotEmpty) {
      request['options'] = {
        if (pending != null)
          ...pending.messageSendOptions(paidStarCount: count),
        ...existing,
        '@type': 'messageSendOptions',
        if (count > 0) 'paid_message_star_count': count,
      };
    }
    return request;
  }

  void _setPaidMessageStarCount(int count, {bool notify = true}) {
    final next = count < 0 ? 0 : count;
    if (paidMessageStarCount == next) return;
    paidMessageStarCount = next;
    if (notify) notifyListeners();
  }

  Future<bool> prepareMessageSend() async {
    if (!canSendMessages) return false;
    final userId = peerUserId;
    if (isGroup || isSecretChat || peerIsBot || userId == null) return true;
    await _loadPrivatePaidMessageInfo(userId);
    if (peerIsUnavailable) {
      _publishSendFailure(ChatSendFailure.recipientUnavailable());
      return false;
    }
    if (peerRequiresPremiumOrContact) {
      _publishSendFailure(ChatSendFailure.premiumOrContactRequired());
      return false;
    }
    return true;
  }

  /// Points TDLib at a preview mirror for the message's first link when the user
  /// opted in to fixing link previews. Requests that already carry
  /// `link_preview_options` keep them: an explicit choice beats a preference.
  /// The composer's link preview panel answer for the message being typed
  /// (on/off and above/below the text). Null means no explicit choice, so the
  /// fixer's own rules apply. Cleared when the draft's link goes away.
  ComposerLinkPreviewChoice? composerLinkPreview;

  Map<String, dynamic> _withFixedLinkPreview(Map<String, dynamic> request) =>
      LinkPreviewFixer.shared.applyTo(request, choice: composerLinkPreview);

  Future<bool> _submitMessageRequest(Map<String, dynamic> request) async {
    final startedBotTopicId = await _scopeSendToNewBotTopic(request);
    try {
      await _client.query(
        _withPaidMessageOptions(_withFixedLinkPreview(request)),
      );
      return true;
    } catch (error) {
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      return false;
    } finally {
      _announceStartedBotTopic(startedBotTopicId);
    }
  }

  /// Hands the topic a send just started to the transcript host, once the send
  /// outcome is known: the host switches afterwards, so a failed message is
  /// retried inside its topic instead of starting yet another one.
  void _announceStartedBotTopic(int? topicId) {
    if (topicId == null || _isDisposed) return;
    // A multi-segment send announces the same topic once per segment.
    if (_pendingBotTopicOpen == topicId) return;
    _pendingBotTopicOpen = topicId;
    notifyListeners();
  }

  /// Panel fire-and-forget sends: stamps the reply anchor, submits the
  /// request and consumes the reply only after the send actually
  /// succeeded — and only if the user hasn't selected a newer reply in
  /// the meantime. A failed send keeps the reply for retry.
  void _submitPanelMessage(Map<String, dynamic> request) {
    final stamped = _withReplyAnchor(request);
    unawaited(
      _submitMessageRequest(stamped.request).then((sent) {
        if (sent) _consumeReplyAnchorIfCurrent(stamped.revision);
      }),
    );
  }

  void _submitMessageRequestWithoutWaiting(Map<String, dynamic> request) {
    unawaited(_submitMessageRequest(request));
  }

  void _publishSendFailure(ChatSendFailure failure) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSendFailureKey == failure.deduplicationKey &&
        now - _lastSendFailureAtMilliseconds < 1500) {
      return;
    }
    _lastSendFailureKey = failure.deduplicationKey;
    _lastSendFailureAtMilliseconds = now;
    _pendingSendFailure = failure;
    notifyListeners();

    if (failure.kind == ChatSendFailureKind.paidMessageRequired ||
        failure.kind == ChatSendFailureKind.premiumRequired) {
      final userId = peerUserId;
      if (!isGroup && !isSecretChat && userId != null) {
        unawaited(_loadPrivatePaidMessageInfo(userId, force: true));
      }
    }
  }

  // MARK: - Lifecycle

  void onAppear() {
    _client.send({'@type': 'openChat', 'chat_id': chatId});
    _subscribeToUpdates();
    KeywordBlocker.shared.removeListener(_applyKeywordFilter);
    KeywordBlocker.shared.addListener(_applyKeywordFilter);
    HiddenSenderStore.shared.removeListener(_applyKeywordFilter);
    HiddenSenderStore.shared.addListener(_applyKeywordFilter);
    if (allowTelegramTosViolations) {
      MessageHistorySettings.shared.removeListener(_onGhostSourceChanged);
      MessageHistorySettings.shared.addListener(_onGhostSourceChanged);
      MessageHistoryStore.shared.removeListener(_onGhostSourceChanged);
      MessageHistoryStore.shared.addListener(_onGhostSourceChanged);
    }
    () async {
      unawaited(_loadMe());
      unawaited(_loadAiCapabilities());
      unawaited(_loadBotApiAccessInfo());
      await _loadChatHeader();
      if (_chatOpenWorkIsStale) return;
      if (_restoredFromSession) {
        unawaited(_discardStaleRestoredPendingMessages());
        _resolveRichMessagesIfNeeded(messages);
        _resolveSendersIfNeeded(messages);
        _resolveRepliesIfNeeded(messages);
        _resolveForwardsIfNeeded(messages);
        _resolveServiceUsersIfNeeded(messages);
        notifyListeners();
        if (!anchoredHistory) {
          unawaited(_hydrateRestoredLatestHistory());
        }
        unawaited(_loadAvailableMessageSenders());
        return;
      }
      final target = initialMessageId;
      if (target != null) {
        await loadAroundMessage(target);
        if (_chatOpenWorkIsStale) return;
      } else if (sessionAnchorMessageId != null) {
        var restored = await loadAroundMessage(
          sessionAnchorMessageId!,
          scrollToTarget: false,
          onlyLocal: true,
        );
        if (_chatOpenWorkIsStale) return;
        if (!restored) {
          restored = await loadAroundMessage(
            sessionAnchorMessageId!,
            scrollToTarget: false,
          );
          if (_chatOpenWorkIsStale) return;
        }
        if (!restored) {
          await _loadInitialHistory(
            openAtLatest: sessionFallbackOpenAtLatest ?? markReadOnOpen,
          );
          if (_chatOpenWorkIsStale) return;
        }
      } else {
        await _loadInitialHistory(openAtLatest: markReadOnOpen);
        if (_chatOpenWorkIsStale) return;
      }
      initialLoaded = true;
      notifyListeners();
      unawaited(_loadAvailableMessageSenders());
      unawaited(_reconcileMirrorGhosts());
    }();
  }

  Future<void> _loadAiCapabilities() async {
    try {
      aiCapabilities = await telegramAi.capabilities();
      notifyListeners();
    } catch (_) {
      // Capability discovery is optional. Unsupported servers keep all AI
      // entry points hidden instead of exposing actions that will fail.
    }
  }

  void ensureMessageCapabilities(ChatMessage message) {
    if (message.contentType != 'messageVoiceNote' &&
        message.contentType != 'messageVideoNote') {
      return;
    }
    final cached = _speechRecognitionEligibility[message.id];
    if (cached != null) {
      message.canRecognizeSpeech = cached;
      return;
    }
    if (!_messagePropertiesLoading.add(message.id)) return;
    unawaited(_loadMessageCapabilities(message.id));
  }

  Future<void> _loadMessageCapabilities(int messageId) async {
    try {
      final properties = await _client.query({
        '@type': 'getMessageProperties',
        'chat_id': chatId,
        'message_id': messageId,
      });
      final eligible = properties.boolean('can_recognize_speech') ?? false;
      _speechRecognitionEligibility[messageId] = eligible;
      for (final target in _messageRefs(messageId)) {
        target.canRecognizeSpeech = eligible;
      }
      _notifyLocalizedMessages([messageId]);
    } catch (_) {
      _speechRecognitionEligibility[messageId] = false;
    } finally {
      _messagePropertiesLoading.remove(messageId);
    }
  }

  Future<void> _loadMe() async {
    try {
      final me = await _client.query({'@type': 'getMe'});
      meId = me.int64('id');
      final name = TDParse.userName(me);
      if (name.isNotEmpty) meName = name;
      final usernames = me.obj('usernames');
      final active = usernames?['active_usernames'];
      final editable = usernames?.str('editable_username');
      meUsernames = Set.unmodifiable({
        if (active is List)
          for (final username in active.whereType<String>())
            if (username.trim().isNotEmpty)
              username.trim().replaceFirst('@', '').toLowerCase(),
        if (editable?.trim().isNotEmpty == true)
          editable!.trim().replaceFirst('@', '').toLowerCase(),
      });
      mePhoto = TDParse.smallPhoto(me.obj('profile_photo'));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadBotApiAccessInfo() async {
    try {
      final info = await _client.query({'@type': 'getBotApiAccountInfo'});
      if (info.type != 'botApiAccountInfo' || _chatOpenWorkIsStale) return;
      isBotApiAccount = true;
      botApiCanReadAllGroupMessages =
          info.boolean('can_read_all_group_messages') ?? false;
      botApiBotToBotAccessObserved =
          info.boolean('bot_to_bot_access_observed') ?? false;
      notifyListeners();
    } catch (_) {
      // Native TDLib accounts do not implement this Bot API-only query.
    }
  }

  Future<void> _loadAvailableMessageSenders() async {
    try {
      final res = await _client.query({
        '@type': 'getChatAvailableMessageSenders',
        'chat_id': chatId,
      });
      final raw = res.objects('senders') ?? const <Map<String, dynamic>>[];
      final loaded = <MessageSenderOption>[];
      for (final item in raw) {
        final sender = item.obj('sender');
        if (sender == null) continue;
        final option = await _messageSenderOption(
          sender,
          item.boolean('needs_premium') ?? false,
        );
        if (option != null) loaded.add(option);
      }
      availableMessageSenders = loaded;
      selectedMessageSender = preferredMessageSenderOption(
        loaded,
        preferredSender: _messageSenderFromChat,
        current: selectedMessageSender,
      );
      notifyListeners();
    } catch (_) {}
  }

  Future<MessageSenderOption?> _messageSenderOption(
    Map<String, dynamic> sender,
    bool needsPremium,
  ) async {
    switch (sender.type) {
      case 'messageSenderUser':
        final userId = sender.int64('user_id');
        if (userId == null) return null;
        if (peerUserId == userId || userId > 0) {
          try {
            final user = await _client.query({
              '@type': 'getUser',
              'user_id': userId,
            });
            final name = TDParse.userName(user);
            return MessageSenderOption(
              sender: sender,
              id: userId,
              title: name.isEmpty ? meName : name,
              photo: TDParse.smallPhoto(user.obj('profile_photo')),
              needsPremium: needsPremium,
            );
          } catch (_) {}
        }
        return MessageSenderOption(
          sender: sender,
          id: userId,
          title: meName,
          photo: mePhoto,
          needsPremium: needsPremium,
        );
      case 'messageSenderChat':
        final senderChatId = sender.int64('chat_id');
        if (senderChatId == null) return null;
        try {
          final chat = await _client.query({
            '@type': 'getChat',
            'chat_id': senderChatId,
          });
          return MessageSenderOption(
            sender: sender,
            id: senderChatId,
            title: chat.str('title') ?? AppStrings.t(AppStringKeys.tabChannels),
            photo: TDParse.smallPhoto(chat.obj('photo')),
            needsPremium: needsPremium,
          );
        } catch (_) {
          return MessageSenderOption(
            sender: sender,
            id: senderChatId,
            title: AppStrings.t(AppStringKeys.tabChannels),
            needsPremium: needsPremium,
          );
        }
    }
    return null;
  }

  Future<void> selectMessageSender(MessageSenderOption option) async {
    final previous = selectedMessageSender;
    selectedMessageSender = option;
    _messageSenderFromChat = option.sender;
    notifyListeners();
    try {
      await _client.query({
        '@type': 'setChatMessageSender',
        'chat_id': chatId,
        'message_sender_id': option.sender,
      });
    } catch (_) {
      selectedMessageSender = previous;
      _messageSenderFromChat = previous?.sender;
      notifyListeners();
    }
  }

  void onDisappear() {
    if (editingMessage != null) {
      _restoreComposerAfterMessageEdit(notify: false);
    }
    _flushPendingDraftSave();
    _sub?.cancel();
    _sub = null;
    KeywordBlocker.shared.removeListener(_applyKeywordFilter);
    HiddenSenderStore.shared.removeListener(_applyKeywordFilter);
    if (allowTelegramTosViolations) {
      MessageHistorySettings.shared.removeListener(_onGhostSourceChanged);
      MessageHistoryStore.shared.removeListener(_onGhostSourceChanged);
    }
    _client.send({'@type': 'closeChat', 'chat_id': chatId});
  }

  @override
  void dispose() {
    _isDisposed = true;
    KeywordBlocker.shared.removeListener(_applyKeywordFilter);
    HiddenSenderStore.shared.removeListener(_applyKeywordFilter);
    if (allowTelegramTosViolations) {
      MessageHistorySettings.shared.removeListener(_onGhostSourceChanged);
      MessageHistoryStore.shared.removeListener(_onGhostSourceChanged);
    }
    if (_forumTopicIndexListening) {
      ForumTopicIndex.shared.removeListener(_onForumTopicIndexChanged);
      _forumTopicIndexListening = false;
    }
    _sub?.cancel();
    _typingTimer?.cancel();
    _draftSaveTimer?.cancel();
    _coalescedNotifyTimer?.cancel();
    for (final waiter in _messageSendWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Chat view model was disposed'));
      }
    }
    _messageSendWaiters.clear();
    for (final notifier in _messageRevisionNotifiers.values) {
      notifier.dispose();
    }
    _messageRevisionNotifiers.clear();
    _headerRevisionNotifier.dispose();
    telegramAi.dispose();
    super.dispose();
  }

  /// Tell TDLib the user is typing (drives the peer's typing indicator).
  void sendTyping() {
    if (allowTelegramTosViolations &&
        GhostModeController.shared.shouldBlockTyping(chatId).isBlock) {
      return;
    }
    _client.send({
      '@type': 'sendChatAction',
      'chat_id': chatId,
      'topic_id': ?_forumTopicRef,
      'action': {'@type': 'chatActionTyping'},
    });
  }

  // MARK: - Sending

  void setDraft(
    String value, {
    String? formattedText,
    List<Map<String, dynamic>> entities = const [],
  }) {
    draft = value;
    _draftFormattedText = formattedText ?? value;
    _draftFormattedEntities = entities;
    _draftMentions.removeWhere((m) => !draft.contains(m.text));
    if (editingMessage == null) _scheduleDraftSave();
  }

  String get composerFormattedDraft => _draftFormattedText;

  List<Map<String, dynamic>> get composerDraftEntities =>
      List.unmodifiable(_draftFormattedEntities);

  bool get editingMessageUsesCaption => switch (editingMessage?.contentType) {
    'messagePhoto' ||
    'messageVideo' ||
    'messageAnimation' ||
    'messageAudio' ||
    'messageDocument' => true,
    _ => false,
  };

  /// Sends text that may contain inline custom emoji — [entities] is the list of
  /// TDLib textEntity objects (e.g. textEntityTypeCustomEmoji) over [text]
  /// (offsets in UTF-16 of [text], which already has the fallback chars).
  Future<bool> sendFormatted(
    String text,
    List<Map<String, dynamic>> entities,
  ) async {
    if (!canSendMessages) return false;
    if (text.trim().isEmpty) return false;
    if (entities.isEmpty && _diceEmojis.contains(text.trim())) {
      return _sendDice(text);
    }
    final spaced = _spacedOutgoing(text, entities);
    final allEntities = [
      ...spaced.entities,
      ..._mentionEntitiesFor(spaced.text, spaced.entities),
    ];
    final request = <String, dynamic>{
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': spaced.text,
          if (allEntities.isNotEmpty) 'entities': allEntities,
        },
      },
    };
    final replyRevision = _replyRevision;
    if (replyTo != null) {
      request['reply_to'] = replyToInput;
    }
    final sent = await _submitMessageRequest(request);
    if (!sent) return false;
    _consumeReplyAnchorIfCurrent(replyRevision);
    _clearDraft();
    notifyListeners();
    return true;
  }

  Future<void> sendRichMessageHtml(
    String html, {
    List<RichMessageSendFile> files = const [],
    List<Map<String, dynamic>> blocks = const [],
  }) async {
    final botApiDirect = await _client.activeAccountUsesBotApi();
    if (!botApiDirect && blocks.isEmpty) {
      throw StateError('Rich message blocks are required for user accounts');
    }
    for (final file in files) {
      if ((file.attachment.fileId ?? 0) > 0) continue;
      final localFile = File(file.attachment.path);
      if (!await localFile.exists() || await localFile.length() <= 0) {
        throw StateError('Unable to read rich message media');
      }
    }
    _clearDraft();
    final request = <String, dynamic>{
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': botApiDirect
          ? botApiDirectRichMessageInputContent(html, files, blocks: blocks)
          : richMessageInputContent(blocks),
    };
    final replyRevision = _replyRevision;
    if (replyTo != null) {
      request['reply_to'] = replyToInput;
    }
    // A rich message is still a new message: a bot topic chat's "All" view has
    // to start a topic for it exactly like the plain composer path does.
    final startedBotTopicId = await _scopeSendToNewBotTopic(request);
    late final Map<String, dynamic> pendingMessage;
    try {
      pendingMessage = await _client.query(_withPaidMessageOptions(request));
    } finally {
      // Announce before waiting for an upload: the topic exists as soon as
      // the send is accepted, and the user should be reading it while media
      // is still going up.
      _announceStartedBotTopic(startedBotTopicId);
    }
    _consumeReplyAnchorIfCurrent(replyRevision);
    final pendingMessageId = pendingMessage.int64('id');
    if (pendingMessageId != null &&
        pendingMessage.obj('sending_state') != null) {
      await _waitForMessageSend(pendingMessageId);
    }
    notifyListeners();
  }

  Future<bool> currentUserIsPremium() async {
    final user = await _client.query({'@type': 'getMe'});
    return user.boolean('is_premium') ?? false;
  }

  static const _diceEmojis = {'🎲', '🎯', '🏀', '⚽', '🎳', '🎰'};

  Future<bool> _sendDice(String text) async {
    final emoji = text.trim();
    if (!_diceEmojis.contains(emoji)) return false;
    final request = <String, dynamic>{
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {'@type': 'inputMessageDice', 'emoji': emoji},
    };
    final replyRevision = _replyRevision;
    if (replyTo != null) {
      request['reply_to'] = replyToInput;
    }
    final sent = await _submitMessageRequest(request);
    if (!sent) return false;
    _consumeReplyAnchorIfCurrent(replyRevision);
    _clearDraft();
    notifyListeners();
    return true;
  }

  /// Sets or clears the reply target without changing the current draft.
  ///
  /// The reply metadata already addresses the sender. Mentions remain an
  /// explicit action so replying cannot accidentally invoke inline-bot search.
  void setReply(ChatMessage? message, {MessageTextQuote? quote}) {
    if (editingMessage != null) {
      _restoreComposerAfterMessageEdit(notify: false);
    }
    replyTo = message;
    if (message != null && !isSecretChat && quote != null) {
      _replyQuote = quote;
    }
    notifyListeners();
  }

  /// Sets a cross-chat reply: the composer answers in this chat while the
  /// reply banner addresses [message] from [sourceChatId]. TDLib requires
  /// these to travel as `inputMessageReplyToExternalMessage`.
  void setExternalReply(
    ChatMessage message,
    int sourceChatId, {
    MessageTextQuote? quote,
  }) {
    if (editingMessage != null) {
      _restoreComposerAfterMessageEdit(notify: false);
    }
    replyTo = message;
    _replyToChatId = sourceChatId;
    if (!isSecretChat && quote != null) {
      _replyQuote = quote;
    }
    notifyListeners();
  }

  bool get canQuoteText =>
      canSendMessages && !isSecretChat && !hasProtectedContent;

  Future<int> messageQuoteLengthLimit() async {
    try {
      final option = await _client.query({
        '@type': 'getOption',
        'name': 'message_reply_quote_length_max',
      });
      final limit = option.integer('value');
      if (limit != null && limit > 0) return limit;
    } catch (_) {}
    return defaultMessageQuoteLengthLimit;
  }

  /// TDLib's longest caption for this account (Premium raises it), in
  /// Unicode characters.
  Future<int> messageCaptionLengthLimit() async {
    try {
      final option = await _client.query({
        '@type': 'getOption',
        'name': 'message_caption_length_max',
      });
      final limit = option.integer('value');
      if (limit != null && limit > 0) return limit;
    } catch (_) {}
    return defaultMessageCaptionLengthLimit;
  }

  List<Map<String, dynamic>> _mentionEntitiesFor(
    String text,
    List<Map<String, dynamic>> existing,
  ) {
    final out = <Map<String, dynamic>>[];
    final occupied = existing.map((e) {
      final offset = e.integer('offset') ?? 0;
      final length = e.integer('length') ?? 0;
      return (offset, offset + length);
    }).toList();
    for (final mention in _draftMentions) {
      var start = 0;
      while (start < text.length) {
        final offset = text.indexOf(mention.text, start);
        if (offset < 0) break;
        final end = offset + mention.text.length;
        final overlaps = occupied.any((r) => offset < r.$2 && end > r.$1);
        if (!overlaps) {
          out.add({
            '@type': 'textEntity',
            'offset': offset,
            'length': mention.text.length,
            'type': {
              '@type': 'textEntityTypeMentionName',
              'user_id': mention.userId,
            },
          });
          occupied.add((offset, end));
          break;
        }
        start = end;
      }
    }
    return out;
  }

  /// Spaces text this model is about to send, moving its entities onto the new
  /// offsets. Applied here rather than in each composer so every surface that
  /// reaches a send — mobile, desktop, picker windows, media captions — spaces
  /// text the same way, and so mention detection still sees the final text.
  ({String text, List<Map<String, dynamic>> entities}) _spacedOutgoing(
    String text,
    List<Map<String, dynamic>> entities, {
    bool editing = false,
  }) => PanguSpacing.gated(
    enabled: editing ? panguOnEdit : panguOnSend,
    text: text,
    entities: entities,
  );

  Future<void> sendAttachments(
    List<OutgoingAttachment> attachments, {
    String caption = '',
    List<Map<String, dynamic>> captionEntities = const [],
    MessageSendConfiguration sendConfiguration =
        const MessageSendConfiguration(),
  }) async {
    if (attachments.isEmpty) return;
    // Capture the reply before re-encoding can yield to a reply change.
    final replyRevision = _replyRevision;
    final replyTo = replyToInput;
    // The picker hands over measured originals, so composers that skip
    // resolveAttachmentDimensions still need Telegram's photo limits applied.
    attachments = await Future.wait(attachments.map(fitPhotoToTelegramLimits));
    final spaced = _spacedOutgoing(caption, captionEntities);
    final allEntities = [
      ...spaced.entities,
      ..._mentionEntitiesFor(spaced.text, spaced.entities),
    ];
    final requests = buildAttachmentSendRequests(
      chatId: chatId,
      topicId: _forumTopicRef,
      attachments: attachments,
      caption: spaced.text,
      captionEntities: allEntities,
      replyTo: replyTo,
      sendConfiguration: sendConfiguration,
    );
    _clearDraft();
    notifyListeners();
    try {
      for (final request in requests) {
        await _client.query(
          _withPaidMessageOptions(
            request,
            sendConfiguration: sendConfiguration,
            consumePendingConfiguration: false,
          ),
        );
      }
      _consumeReplyAnchorIfCurrent(replyRevision);
    } catch (error) {
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      rethrow;
    }
  }

  void sendPhoto(
    String path, {
    String caption = '',
    List<Map<String, dynamic>> captionEntities = const [],
  }) {
    final captionText = captionEntities.isEmpty ? caption.trim() : caption;
    _submitPanelMessage({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessagePhoto',
        'photo': {
          '@type': 'inputPhoto',
          'photo': {'@type': 'inputFileLocal', 'path': path},
        },
        if (captionText.trim().isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': captionText,
            if (captionEntities.isNotEmpty) 'entities': captionEntities,
          },
      },
    });
  }

  void sendVideo(
    String path, {
    String caption = '',
    List<Map<String, dynamic>> captionEntities = const [],
  }) {
    final captionText = captionEntities.isEmpty ? caption.trim() : caption;
    _submitPanelMessage({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageVideo',
        'video': {
          '@type': 'inputVideo',
          'video': {'@type': 'inputFileLocal', 'path': path},
          'supports_streaming': true,
        },
        if (captionText.trim().isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': captionText,
            if (captionEntities.isNotEmpty) 'entities': captionEntities,
          },
      },
    });
  }

  void sendAnimation(
    String path, {
    String caption = '',
    List<Map<String, dynamic>> captionEntities = const [],
  }) {
    final captionText = captionEntities.isEmpty ? caption.trim() : caption;
    _submitPanelMessage({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageAnimation',
        'animation': {
          '@type': 'inputAnimation',
          'animation': {'@type': 'inputFileLocal', 'path': path},
          'duration': 0,
          'width': 0,
          'height': 0,
        },
        if (captionText.trim().isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': captionText,
            if (captionEntities.isNotEmpty) 'entities': captionEntities,
          },
      },
    });
  }

  Future<bool> sendGif(
    GifItem gif, {
    MessageSendConfiguration? sendConfiguration,
  }) async {
    if (!canSendMessages) return false;
    if (sendConfiguration != null) {
      useNextSendConfiguration(sendConfiguration);
    }
    try {
      final stamped = _withReplyAnchor(
        gifSendRequest(chatId: chatId, gif: gif),
      );
      final pendingMessage = await _client.query(
        _withPaidMessageOptions(stamped.request),
      );
      final pendingMessageId = pendingMessage.int64('id');
      if (pendingMessageId != null &&
          pendingMessage.obj('sending_state') != null) {
        await _waitForMessageSend(pendingMessageId);
      }
      _consumeReplyAnchorIfCurrent(stamped.revision);
      return true;
    } catch (error) {
      debugPrint('Failed to send GIF: $error');
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      return false;
    }
  }

  Future<bool> sendSticker(
    StickerItem sticker, {
    MessageSendConfiguration? sendConfiguration,
  }) async {
    if (!canSendMessages) return false;
    if (sendConfiguration != null) {
      useNextSendConfiguration(sendConfiguration);
    }
    try {
      final stamped = _withReplyAnchor(stickerMessageRequest(sticker));
      final pendingMessage = await _client.query(stamped.request);
      final pendingMessageId = pendingMessage.int64('id');
      if (pendingMessageId != null &&
          pendingMessage.obj('sending_state') != null) {
        await _waitForMessageSend(pendingMessageId);
      }
      _consumeReplyAnchorIfCurrent(stamped.revision);
      return true;
    } catch (error) {
      debugPrint('Failed to send sticker: $error');
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      return false;
    }
  }

  /// Sends one voice note. A non-empty [caption] travels on the same message
  /// (`inputMessageVoiceNote.caption`) and clears the composer draft once
  /// TDLib accepts it, as a sent text would.
  ///
  /// With [reportGenericFailure] false, a failure the user can do nothing
  /// about beyond retrying is left to the caller to show; failures that need
  /// an action (stars, Premium, privacy, permissions…) are still published.
  Future<bool> sendVoice(
    String path,
    int duration, {
    String waveform = '',
    String caption = '',
    List<Map<String, dynamic>> captionEntities = const [],
    MessageSendConfiguration sendConfiguration =
        const MessageSendConfiguration(),
    bool reportGenericFailure = true,
  }) async {
    if (!canSendMessages || !canSendVoiceNotes) return false;
    final hasCaption = caption.trim().isNotEmpty;
    final spaced = hasCaption
        ? _spacedOutgoing(caption, captionEntities)
        : (text: '', entities: const <Map<String, dynamic>>[]);
    final allEntities = [
      ...spaced.entities,
      if (hasCaption) ..._mentionEntitiesFor(spaced.text, spaced.entities),
    ];
    try {
      final stamped = _withReplyAnchor(
        _withPaidMessageOptions({
          '@type': 'sendMessage',
          'chat_id': chatId,
          'input_message_content': {
            '@type': 'inputMessageVoiceNote',
            'voice_note': {
              '@type': 'inputVoiceNote',
              'voice_note': {'@type': 'inputFileLocal', 'path': path},
              'duration': duration,
              'waveform': waveform,
            },
            if (hasCaption)
              'caption': {
                '@type': 'formattedText',
                'text': spaced.text,
                if (allEntities.isNotEmpty) 'entities': allEntities,
              },
            'self_destruct_type': ?sendConfiguration.selfDestructType,
          },
        }, sendConfiguration: sendConfiguration),
      );
      await _client.query(stamped.request);
      _consumeReplyAnchorIfCurrent(stamped.revision);
      if (hasCaption) {
        _clearDraft();
        notifyListeners();
      }
      return true;
    } catch (error) {
      if (_isVoiceMessageRestrictionError(error)) {
        canSendVoiceNotes = false;
        notifyListeners();
      }
      debugPrint('Failed to send voice note: $error');
      final failure = ChatSendFailure.fromError(
        error,
        paidMessageStarCount: paidMessageStarCount,
      );
      if (reportGenericFailure || failure.kind != ChatSendFailureKind.generic) {
        _publishSendFailure(failure);
      }
      return false;
    }
  }

  Future<bool> sendVideoNote(
    String path,
    int duration, {
    MessageSendConfiguration sendConfiguration =
        const MessageSendConfiguration(),
  }) async {
    try {
      final stamped = _withReplyAnchor(
        _withPaidMessageOptions({
          '@type': 'sendMessage',
          'chat_id': chatId,
          'input_message_content': {
            '@type': 'inputMessageVideoNote',
            'video_note': {
              '@type': 'inputVideoNote',
              'video_note': {'@type': 'inputFileLocal', 'path': path},
              'duration': duration,
              'length': 0,
            },
            'self_destruct_type': ?sendConfiguration.selfDestructType,
          },
        }, sendConfiguration: sendConfiguration),
      );
      await _client.query(stamped.request);
      _consumeReplyAnchorIfCurrent(stamped.revision);
      return true;
    } catch (error) {
      debugPrint('Failed to send video note: $error');
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      return false;
    }
  }

  /// 音频: send a picked audio file as a music message (TDLib computes metadata).
  void sendAudio(String path) {
    _submitPanelMessage({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageAudio',
        'audio': {
          '@type': 'inputAudio',
          'audio': {'@type': 'inputFileLocal', 'path': path},
          'duration': 0,
          'title': '',
          'performer': '',
        },
      },
    });
  }

  /// 音频搜索: send a clean copy of an existing Telegram audio message.
  Future<void> sendAudioFromMessage(
    int sourceChatId,
    ChatMessage message,
  ) async {
    await assertForwardAllowed(
      query: _client.query,
      fromChatId: sourceChatId,
      messageIds: [message.id],
      options: const ForwardOptions(removeSender: true),
    );
    final music = message.music;
    final fileId = music?.file?.id;
    Map<String, dynamic>? topicRef;
    int? startedTopicId;
    if (music != null && fileId != null && fileId > 0) {
      final audioRequest = <String, dynamic>{
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageAudio',
          'audio': {
            '@type': 'inputAudio',
            'audio': {'@type': 'inputFileId', 'id': fileId},
            'duration': music.duration,
            'title': music.title,
            'performer': music.performer ?? '',
          },
        },
      };
      startedTopicId = await _scopeSendToNewBotTopic(audioRequest);
      topicRef = audioRequest.obj('topic_id');
      try {
        await _client.query(_withPaidMessageOptions(audioRequest));
        _announceStartedBotTopic(startedTopicId);
        return;
      } catch (_) {
        // Fall back to a copy of the original message below; the topic this
        // attempt started (if any) is reused so the copy lands inside it.
      }
    }
    final forwardRequest = <String, dynamic>{
      '@type': 'forwardMessages',
      'chat_id': chatId,
      'topic_id': ?topicRef,
      'from_chat_id': sourceChatId,
      'message_ids': [message.id],
      'options': {'@type': 'messageSendOptions'},
      'send_copy': true,
      'remove_caption': false,
    };
    final startedForwardTopicId = await _scopeSendToNewBotTopic(forwardRequest);
    try {
      await _client.query(_withPaidMessageOptions(forwardRequest));
    } finally {
      _announceStartedBotTopic(startedTopicId ?? startedForwardTopicId);
    }
  }

  /// 清单: send a checklist (to-do list). Creating checklists needs Premium.
  void sendChecklist(ChecklistComposerResult draft) {
    if (draft.title.trim().isEmpty || draft.tasks.isEmpty) return;
    _submitPanelMessage({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageChecklist',
        'checklist': ChecklistRequests.inputChecklist(draft),
      },
    });
  }

  Future<void> editChecklist(
    ChatMessage message,
    ChecklistComposerResult draft,
  ) async {
    final checklist = message.checklist;
    if (checklist == null) return;
    await _client.query(
      ChecklistRequests.edit(
        chatId: chatId,
        messageId: message.id,
        original: checklist,
        draft: draft,
      ),
    );
    await _refreshMessage(message.id);
  }

  Future<int> pollAnswerCountMax() async {
    try {
      final option = await _client.query({
        '@type': 'getOption',
        'name': 'poll_answer_count_max',
      });
      return (option.integer('value') ?? 30).clamp(2, 100);
    } catch (_) {
      return 30;
    }
  }

  Future<bool> sendPoll(PollComposerResult draft) async {
    final question = draft.question.trim();
    final options = draft.options
        .where((option) => option.text.trim().isNotEmpty)
        .toList(growable: false);
    if (question.isEmpty || options.length < 2) return false;
    if (draft.isQuiz && draft.correctOptionIndexes.isEmpty) return false;
    try {
      final stamped = _withReplyAnchor(
        _withPaidMessageOptions({
          '@type': 'sendMessage',
          'chat_id': chatId,
          'input_message_content': {
            '@type': 'inputMessagePoll',
            'question': {'@type': 'formattedText', 'text': question},
            'options': [
              for (final option in options)
                {
                  '@type': 'inputPollOption',
                  'text': {
                    '@type': 'formattedText',
                    'text': option.text.trim(),
                  },
                  if (option.mediaPath case final path?)
                    'media': _inputPollPhoto(path),
                },
            ],
            if (draft.description.trim().isNotEmpty)
              'description': {
                '@type': 'formattedText',
                'text': draft.description.trim(),
              },
            if (draft.pollMediaPath case final path?)
              'media': _inputPollPhoto(path),
            'is_anonymous': draft.isAnonymous,
            'allows_multiple_answers': draft.allowsMultipleAnswers,
            'allows_revoting': draft.allowsRevoting,
            'shuffle_options': draft.shuffleOptions,
            'hide_results_until_closes': draft.hideResultsUntilCloses,
            'type': draft.isQuiz
                ? {
                    '@type': 'inputPollTypeQuiz',
                    'correct_option_ids': draft.correctOptionIndexes.toList()
                      ..sort(),
                    'explanation': {
                      '@type': 'formattedText',
                      'text': draft.explanation.trim(),
                    },
                  }
                : {
                    '@type': 'inputPollTypeRegular',
                    'allow_adding_options': draft.allowAddingOptions,
                  },
            'open_period': draft.openPeriod,
          },
        }),
      );
      await _client.query(stamped.request);
      _consumeReplyAnchorIfCurrent(stamped.revision);
      return true;
    } catch (error) {
      debugPrint('Failed to send poll: $error');
      _publishSendFailure(
        ChatSendFailure.fromError(
          error,
          paidMessageStarCount: paidMessageStarCount,
        ),
      );
      return false;
    }
  }

  Map<String, dynamic> _inputPollPhoto(String path) => {
    '@type': 'inputPollMediaPhoto',
    'photo': {
      '@type': 'inputPhoto',
      'photo': {'@type': 'inputFileLocal', 'path': path},
    },
  };

  Future<void> addPollOption(ChatMessage message, String text) async {
    final value = text.trim();
    if (message.poll == null || value.isEmpty) return;
    await _client.query({
      '@type': 'addPollOption',
      'chat_id': chatId,
      'message_id': message.id,
      'option': {
        '@type': 'inputPollOption',
        'text': {'@type': 'formattedText', 'text': value},
      },
    });
    await _refreshMessage(message.id);
  }

  Future<void> recognizeSpeech(ChatMessage message) async {
    if (!canUseSpeechRecognition) {
      throw StateError('SPEECH_RECOGNITION_UNAVAILABLE');
    }
    final properties = await _client.query({
      '@type': 'getMessageProperties',
      'chat_id': chatId,
      'message_id': message.id,
    });
    if (properties.boolean('can_recognize_speech') != true) {
      _speechRecognitionEligibility[message.id] = false;
      for (final target in _messageRefs(message.id)) {
        target.canRecognizeSpeech = false;
      }
      _notifyLocalizedMessages([message.id]);
      throw StateError('SPEECH_RECOGNITION_UNAVAILABLE');
    }
    await _client.query({
      '@type': 'recognizeSpeech',
      'chat_id': chatId,
      'message_id': message.id,
    });
    await _refreshMessage(message.id);
  }

  Future<Map<String, dynamic>> pollVoteStatistics(
    ChatMessage message, {
    required bool isDark,
  }) => _client.query({
    '@type': 'getPollVoteStatistics',
    'chat_id': chatId,
    'message_id': message.id,
    'is_dark': isDark,
  });

  Future<List<Map<String, dynamic>>> pollVoters(
    ChatMessage message,
    int optionIndex, {
    int offset = 0,
  }) async {
    final response = await _client.query({
      '@type': 'getPollVoters',
      'chat_id': chatId,
      'message_id': message.id,
      'option_id': optionIndex,
      'offset': offset,
      'limit': 50,
    });
    return response.objects('voters') ?? const <Map<String, dynamic>>[];
  }

  Future<void> votePoll(ChatMessage message, int optionIndex) async {
    final poll = message.poll;
    if (poll == null || poll.isClosed) return;
    final selected = <int>[...poll.chosenOptionIndexes];
    if (poll.allowsMultipleAnswers) {
      selected.contains(optionIndex)
          ? selected.remove(optionIndex)
          : selected.add(optionIndex);
    } else if (selected.length == 1 && selected.first == optionIndex) {
      if (!poll.allowsRevoting) return;
      selected.clear();
    } else {
      selected
        ..clear()
        ..add(optionIndex);
    }
    await _client.query({
      '@type': 'setPollAnswer',
      'chat_id': chatId,
      'message_id': message.id,
      'option_ids': selected,
    });
    await _refreshMessage(message.id);
  }

  Future<void> stopPoll(ChatMessage message) async {
    if (message.poll == null || message.poll!.isClosed) return;
    await _client.query({
      '@type': 'stopPoll',
      'chat_id': chatId,
      'message_id': message.id,
    });
    await _refreshMessage(message.id);
  }

  Future<void> toggleChecklistTask(
    ChatMessage message,
    MessageChecklistTask task,
  ) async {
    final checklist = message.checklist;
    if (checklist == null || !checklist.canMarkTasksAsDone) return;
    await _client.query({
      '@type': 'markChecklistTasksAsDone',
      'chat_id': chatId,
      'message_id': message.id,
      'marked_as_done_task_ids': task.isCompleted ? <int>[] : [task.id],
      'marked_as_not_done_task_ids': task.isCompleted ? [task.id] : <int>[],
    });
    await _refreshMessage(message.id);
  }

  Future<void> addChecklistTask(ChatMessage message, String text) async {
    final checklist = message.checklist;
    final value = text.trim();
    if (checklist == null || !checklist.canAddTasks || value.isEmpty) return;
    final nextId =
        checklist.tasks.fold<int>(
          0,
          (current, task) => math.max(current, task.id),
        ) +
        1;
    await _client.query({
      '@type': 'addChecklistTasks',
      'chat_id': chatId,
      'message_id': message.id,
      'tasks': [
        {
          '@type': 'inputChecklistTask',
          'id': nextId,
          'text': {'@type': 'formattedText', 'text': value},
        },
      ],
    });
    await _refreshMessage(message.id);
  }

  /// Re-sends the same content (the "+1" quick repeat) — only plain text and
  /// photos; the badge that calls this is gated to those kinds too.
  void repeatMessage(ChatMessage message) {
    if (hasProtectedContent) return;
    // Photo: send a clean copy (forwardMessages send_copy drops the "转发"
    // header and works regardless of the original file's upload state).
    if (message.isPhoto && message.image != null) {
      _submitMessageRequestWithoutWaiting({
        '@type': 'forwardMessages',
        'chat_id': chatId,
        'from_chat_id': chatId,
        'message_ids': [message.id],
        'send_copy': true,
      });
      return;
    }
    if (!message.isPlainText) return;
    final text = message.text.trim();
    if (text.isEmpty) return;
    _submitMessageRequestWithoutWaiting({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    });
  }

  bool sendKeyboardButtonText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    _submitMessageRequestWithoutWaiting({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': trimmed},
      },
    });
    return true;
  }

  bool sendCommand(String command) {
    final trimmed = command.trim();
    if (!trimmed.startsWith('/')) return false;
    _sendText(trimmed);
    return true;
  }

  Future<Map<String, dynamic>> answerCallbackButton(
    int messageId,
    MessageButton button,
  ) async {
    final answer = await _client.query({
      '@type': 'getCallbackQueryAnswer',
      'chat_id': chatId,
      'message_id': messageId,
      'payload': {
        '@type': 'callbackQueryPayloadData',
        'data': button.data ?? '',
      },
    });
    await _refreshMessage(messageId);
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 700),
        () => _refreshMessage(messageId),
      ),
    );
    return answer;
  }

  Future<void> _refreshMessage(int messageId) async {
    if (_isDisposed) return;
    try {
      final raw = await _client.query({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      if (_isDisposed) return;
      final refreshed = _parseMessage(raw);
      if (refreshed == null) return;
      _merge([refreshed]);
      _resolveRichMessagesIfNeeded([refreshed]);
      _resolveSendersIfNeeded([refreshed]);
      _resolveRepliesIfNeeded([refreshed]);
      _resolveForwardsIfNeeded([refreshed]);
      _resolveServiceUsersIfNeeded([refreshed]);
    } catch (_) {
      // Live TDLib updates remain the source of truth if a direct refresh fails.
    }
  }

  Future<MessageTranslationResult> translateMessage(
    int messageId,
    String toLanguageCode,
  ) async {
    _setTranslationLoading(messageId, true);
    try {
      final formatted = await _client.query({
        '@type': 'translateMessageText',
        'chat_id': chatId,
        'message_id': messageId,
        'to_language_code': toLanguageCode,
      });
      final result = (
        text: formatted.str('text') ?? '',
        entities: TDParse.textEntities(formatted),
        languageCode: toLanguageCode,
      );
      _replaceTranslation(
        messageId,
        result.text,
        result.entities,
        result.languageCode,
      );
      return result;
    } catch (_) {
      _setTranslationLoading(messageId, false);
      rethrow;
    }
  }

  Future<String> translateText(String text, String toLanguageCode) async {
    final formatted = await _client.query({
      '@type': 'translateText',
      'text': {
        '@type': 'formattedText',
        'text': text,
        'entities': const <Map<String, dynamic>>[],
      },
      'to_language_code': toLanguageCode,
    });
    return formatted.str('text') ?? '';
  }

  Future<void> summarizeMessage(
    ChatMessage message, {
    String translateToLanguageCode = '',
    String tone = 'neutral',
  }) async {
    if (!canUseAiSummary ||
        message.summaryLanguageCode.isEmpty ||
        message.aiSummaryLoading) {
      return;
    }
    final targets = _messageRefs(message.id);
    for (final target in targets) {
      target.aiSummaryLoading = true;
    }
    _notifyLocalizedMessages([message.id]);
    try {
      final result = await telegramAi.summarize(
        chatId: chatId,
        messageId: message.id,
        translateToLanguageCode: translateToLanguageCode,
        tone: tone,
      );
      final formatted = result.toTdJson();
      for (final target in _messageRefs(message.id)) {
        target.aiSummaryText = result.text;
        target.aiSummaryEntities = TDParse.textEntities(formatted);
        target.aiSummaryLoading = false;
      }
      _notifyLocalizedMessages([message.id]);
    } catch (_) {
      for (final target in _messageRefs(message.id)) {
        target.aiSummaryLoading = false;
      }
      _notifyLocalizedMessages([message.id]);
      rethrow;
    }
  }

  Future<MessageTranslationResult> translateMessageExternally(
    int messageId,
    String toLanguageCode,
    Future<String> Function() translate, {
    bool showLoading = true,
  }) async {
    if (showLoading) _setTranslationLoading(messageId, true);
    try {
      final translated = await translate();
      _replaceTranslation(messageId, translated, const [], toLanguageCode);
      return (
        text: translated,
        entities: const <MessageTextEntity>[],
        languageCode: toLanguageCode,
      );
    } catch (_) {
      if (showLoading) _setTranslationLoading(messageId, false);
      rethrow;
    }
  }

  // MARK: - Message actions (long-press menu)

  /// The composer's pending forward (forward-to-chat). Set when the
  /// transcript opens with a [ForwardMessagesHandoff]; cleared on send,
  /// cancel, or reply selection.
  PendingForward? pendingForward;

  /// Installs a forward carried from the picking chat. A pending reply and a
  /// pending forward cannot coexist — the composer shows one banner — so
  /// adopting a forward drops the reply, exactly like exteraless's field
  /// panel swap. A forward whose target is this same chat (转发到本聊天)
  /// stays here and adopts too: the composer preview holds it until send.
  void adoptForwardHandoff(ForwardMessagesHandoff handoff) {
    if (handoff.accountSlot != _accountSlot ||
        handoff.clientId != _accountClientId) {
      return;
    }
    replyTo = null;
    pendingForward = pendingForwardFromHandoff(handoff);
    notifyListeners();
  }

  void clearPendingForward() {
    if (pendingForward == null) return;
    pendingForward = null;
    notifyListeners();
  }

  /// The forward options sheet mutated the pending forward's toggles in
  /// place; re-notify so the composer banner below the sheet reflects them.
  void notifyForwardOptionsChanged() {
    if (pendingForward == null) return;
    notifyListeners();
  }

  /// Sends the composer's pending forward into this chat and clears it.
  /// The result plan surfaces through [protectedForwardLastPlan] for the
  /// partial-migration toast, exactly like the in-chat forward path.
  Future<void> sendPendingForward() async {
    final forward = pendingForward;
    if (forward == null) return;
    final messageIds = [
      for (final message in forward.messages)
        if (message.id > 0) message.id,
    ];
    if (messageIds.isEmpty) {
      pendingForward = null;
      notifyListeners();
      return;
    }
    // A bot topic chat has no General topic, so a forward dropped into its
    // "All" view must start a topic first — exteraless retargets the pending
    // forward's top message the same way.
    final startedTopicId = _forumTopicRef == null && _inBotTopicAllView
        ? await _createBotTopicForSend(
            AppStrings.t(AppStringKeys.topicChatTopicTitle),
          )
        : null;
    try {
      await _sendPendingForwardInto(
        forward,
        messageIds,
        startedTopicId == null
            ? _forumTopicRef
            : {'@type': 'messageTopicForum', 'forum_topic_id': startedTopicId},
      );
    } finally {
      _announceStartedBotTopic(startedTopicId);
    }
  }

  Future<void> _sendPendingForwardInto(
    PendingForward forward,
    List<int> messageIds,
    Map<String, dynamic>? topicRef,
  ) async {
    if (forward.protectedCopy) {
      final plan = await forwardProtectedAsCopy(
        query: _client.query,
        fromChatId: forward.fromChatId,
        messageIds: messageIds,
        targetChatId: chatId,
        topicId: topicRef,
      );
      protectedForwardLastPlan = plan;
      pendingForward = null;
      notifyListeners();
      if (plan.anythingSent) return;
      throw const ForwardBlockedException();
    }
    // Source ids are pinned to the account that supplied them; the same
    // account owns this transcript, so the owned query route is exact.
    final forwardQuery = forwardQueryForOwner(
      _client,
      accountSlot: forward.accountSlot,
      clientId: forward.clientId,
    );
    var richText = forward.options.richText;
    // Same second gate as forwardMany: entry points hide the chip for
    // non-Premium, but the entitlement is re-checked here against the live
    // TDLib state.
    if (richText) {
      try {
        final user = await forwardQuery({'@type': 'getMe'});
        richText = user.boolean('is_premium') ?? false;
      } catch (_) {
        richText = false;
      }
    }
    final byId = {for (final message in forward.messages) message.id: message};
    final pendingIds = <int>[];
    // The handoff's messages carry the text the offer was computed from, so
    // the rich-text conversion works even though the source transcript's
    // view model is long gone.
    bool converts(ChatMessage message) =>
        forwardMarkdownOfferForMessage(message).available;
    Future<void> flush() async {
      if (pendingIds.isEmpty) return;
      final ids = List<int>.of(pendingIds);
      pendingIds.clear();
      await forwardMessagesWithOptions(
        client: _client,
        targetChatId: chatId,
        fromChatId: forward.fromChatId,
        messageIds: ids,
        topicId: topicRef,
        options: forward.options,
        query: forwardQuery,
      );
    }

    if (!richText) {
      await forwardMessagesWithOptions(
        client: _client,
        targetChatId: chatId,
        fromChatId: forward.fromChatId,
        messageIds: messageIds,
        topicId: topicRef,
        options: forward.options,
        query: forwardQuery,
      );
    } else {
      for (final id in messageIds) {
        final message = byId[id];
        if (message == null || !converts(message)) {
          pendingIds.add(id);
          continue;
        }
        await flush();
        final sent = await sendMarkdownRichTextForward(
          query: forwardQuery,
          fromChatId: forward.fromChatId,
          messageId: id,
          targetChatId: chatId,
          text: message.text,
          topicId: topicRef,
        );
        if (!sent) pendingIds.add(id);
      }
      await flush();
    }
    pendingForward = null;
    notifyListeners();
  }

  Future<void> forward(
    int messageId,
    int targetChatId, {
    ForwardOptions options = const ForwardOptions(),
  }) async {
    await forwardMany([messageId], targetChatId, options: options);
  }

  Future<void> forwardMany(
    List<int> messageIds,
    int targetChatId, {
    ForwardOptions options = const ForwardOptions(),
  }) async {
    // Protected source + the kept-messages toggle: re-send as a copy
    // (exteraless ForwardProtectedAsCopy). The plan's counts surface
    // through ProtectedForwardResult below; a fully-uncopyable selection
    // still throws so the UI keeps its single failure path.
    if (hasProtectedContent &&
        MessageHistorySettings.shared.forwardProtectedAsCopy) {
      final plan = await forwardProtectedAsCopy(
        query: _client.query,
        fromChatId: chatId,
        messageIds: messageIds,
        targetChatId: targetChatId,
        topicId: targetChatId == chatId ? _forumTopicRef : null,
      );
      protectedForwardLastPlan = plan;
      if (plan.anythingSent) return;
      throw const ForwardBlockedException();
    }
    if (hasProtectedContent) throw const ForwardBlockedException();
    final forwardQuery = forwardQueryForOwner(
      _client,
      accountSlot: _accountSlot,
      clientId: _accountClientId,
    );
    var richText = options.richText;
    // Second gate: entry points already hide the option for non-Premium, but
    // forwardMany is callable without them (bot relay, shortcuts), so the
    // entitlement is re-checked here against the live TDLib state.
    if (richText) {
      final user = await forwardQuery({'@type': 'getMe'});
      richText = user.boolean('is_premium') ?? false;
    }
    if (!richText) {
      await forwardMessagesWithOptions(
        client: _client,
        targetChatId: targetChatId,
        fromChatId: chatId,
        messageIds: messageIds,
        topicId: targetChatId == chatId ? _forumTopicRef : null,
        options: options,
        query: forwardQuery,
      );
      return;
    }
    // Process the selection in order so a mix of converted and ordinary
    // messages still arrives in the order the user picked them: ordinary
    // messages are flushed as contiguous forwardMessages batches before the
    // next converted re-send.
    final byId = {for (final message in _allMessages) message.id: message};
    final pendingIds = <int>[];
    Future<void> flush() async {
      if (pendingIds.isEmpty) return;
      final ids = List<int>.of(pendingIds);
      pendingIds.clear();
      await forwardMessagesWithOptions(
        client: _client,
        targetChatId: targetChatId,
        fromChatId: chatId,
        messageIds: ids,
        topicId: targetChatId == chatId ? _forumTopicRef : null,
        options: options,
        query: forwardQuery,
      );
    }

    for (final id in messageIds) {
      final message = byId[id];
      // Markdown detection is best-effort: any message that fails detection
      // or conversion simply falls back to the regular forward batch.
      if (message == null ||
          !forwardMarkdownOfferForMessage(message).available) {
        pendingIds.add(id);
        continue;
      }
      // Flush the ordinary messages selected before this one so the re-send
      // lands after them; if the conversion fails the message rejoins the
      // pending batch and order is still preserved.
      await flush();
      final sent = await sendMarkdownRichTextForward(
        query: forwardQuery,
        fromChatId: chatId,
        messageId: id,
        targetChatId: targetChatId,
        text: message.text,
        topicId: targetChatId == chatId ? _forumTopicRef : null,
      );
      if (!sent) pendingIds.add(id);
    }
    await flush();
  }

  Future<void> saveToFavorites(int messageId) async {
    await saveToFavoritesMany([messageId]);
  }

  Future<void> saveToFavoritesMany(List<int> messageIds) async {
    if (messageIds.isEmpty) return;
    if (hasProtectedContent) throw const ForwardBlockedException();
    final me = await _client.query({'@type': 'getMe'});
    final myId = me.int64('id');
    if (myId == null) throw TdError({'message': 'Missing current user id'});
    final saved = await _client.query({
      '@type': 'createPrivateChat',
      'user_id': myId,
      'force': false,
    });
    final savedChatId = saved.int64('id');
    if (savedChatId == null) {
      throw TdError({'message': 'Missing Saved Messages chat id'});
    }
    await forwardMessagesWithOptions(
      client: _client,
      targetChatId: savedChatId,
      fromChatId: chatId,
      messageIds: messageIds,
    );
  }

  void saveFavoriteSticker(int fileId) {
    _client.send({
      '@type': 'addFavoriteSticker',
      'sticker': {'@type': 'inputFileId', 'id': fileId},
    });
  }

  void removeFavoriteSticker(int fileId) {
    _client.send({
      '@type': 'removeFavoriteSticker',
      'sticker': {'@type': 'inputFileId', 'id': fileId},
    });
  }

  void removeRecentSticker(int fileId) {
    _client.send({
      '@type': 'removeRecentSticker',
      'is_attached': false,
      'sticker': {'@type': 'inputFileId', 'id': fileId},
    });
  }

  void addSavedAnimation(GifItem gif) {
    _client.send({
      '@type': 'addSavedAnimation',
      'animation': {'@type': 'inputFileId', 'id': gif.id},
    });
  }

  void removeSavedAnimation(GifItem gif) {
    _client.send({
      '@type': 'removeSavedAnimation',
      'animation': {'@type': 'inputFileId', 'id': gif.id},
    });
  }

  Future<void> deleteMessage(int id) {
    return deleteMessages([id]);
  }

  Future<void> deleteMessages(List<int> ids) async {
    if (ids.isEmpty) return;
    await _client.query({
      '@type': 'deleteMessages',
      'chat_id': chatId,
      'message_ids': ids,
      'revoke': true,
    });
    _removeMessages(ids);
  }

  Future<void> deleteMessagesFromSender(ChatMessage message) async {
    final senderId = message.senderId;
    final sender = _messageSenderFor(message);
    if (senderId == null || sender == null) {
      throw TdError({'message': 'Missing message sender'});
    }
    await _client.query({
      '@type': 'deleteChatMessagesBySender',
      'chat_id': chatId,
      'sender_id': sender,
    });
    final ids = _allMessages
        .where((candidate) => candidate.senderId == senderId)
        .map((candidate) => candidate.id)
        .toList();
    _removeMessages(ids);
  }

  Future<void> reportMessage(ChatMessage message) async {
    await _reportTelegramContent(message);
  }

  /// Reports one sender's reaction on a message. The caller must have checked
  /// the message's `can_report_reactions` property first; the write stays on
  /// the client that owns this pane, so a dialog confirmed after an account
  /// switch cannot report into the replacement account.
  Future<void> reportReaction(ChatMessage message, int senderId) async {
    await _client.queryTo({
      '@type': 'reportMessageReactions',
      'chat_id': chatId,
      'message_id': message.id,
      'sender_id': senderId > 0
          ? {'@type': 'messageSenderUser', 'user_id': senderId}
          : {'@type': 'messageSenderChat', 'chat_id': senderId},
    }, _accountClientId);
  }

  Future<void> blockSender(ChatMessage message) async {
    final senderId = message.senderId;
    final sender = _messageSenderFor(message);
    if (senderId == null || sender == null) {
      throw TdError({'message': 'Missing message sender'});
    }
    _blockedSenderIds.add(senderId);
    KeywordBlocker.shared.addBlockedSender(senderId);
    _applyKeywordFilter();
    try {
      await _client.query({
        '@type': 'setMessageSenderBlockList',
        'sender_id': sender,
        'block_list': {'@type': 'blockListMain'},
      });
    } catch (_) {
      _blockedSenderIds.remove(senderId);
      KeywordBlocker.shared.removeBlockedSender(senderId);
      _applyKeywordFilter();
      rethrow;
    }
  }

  Future<void> blockAndReportSender(ChatMessage message) async {
    await blockSender(message);
    unawaited(_reportTelegramContent(message).catchError((_) {}));
  }

  Map<String, dynamic>? _messageSenderFor(ChatMessage message) {
    final senderId = message.senderId;
    if (senderId == null) return null;
    if (senderId > 0) {
      return {'@type': 'messageSenderUser', 'user_id': senderId};
    }
    return {'@type': 'messageSenderChat', 'chat_id': senderId};
  }

  Future<void> _reportTelegramContent(ChatMessage message) async {
    final sender = _messageSenderFor(message);
    final base = <String, dynamic>{
      '@type': 'reportChat',
      'chat_id': chatId,
      'message_ids': [message.id],
      'sender_id': sender,
      'option_id': '',
      'text': 'Objectionable or abusive content reported from Mithka.',
    };
    final result = await _client.query(base);
    if (result.type != 'reportChatResultOptionRequired') return;
    final options = result.objects('options') ?? const <Map<String, dynamic>>[];
    if (options.isEmpty) return;
    await _client.query({...base, 'option_id': options.first['id'] ?? ''});
  }

  Future<void> editMessageText(
    int id,
    String text, {
    List<Map<String, dynamic>> entities = const [],
  }) async {
    if (text.trim().isEmpty) return;
    final parsed = TDParse.textEntities({
      '@type': 'formattedText',
      'text': text,
      'entities': entities,
    });
    final previewUrl = LinkPreviewFixer.shared.previewUrl(
      text,
      entities: parsed,
    );
    await _client.query({
      '@type': 'editMessageText',
      'chat_id': chatId,
      'message_id': id,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text,
          if (entities.isNotEmpty) 'entities': entities,
        },
        'link_preview_options': {
          '@type': 'linkPreviewOptions',
          'is_disabled': false,
          'url': ?previewUrl,
        },
        'clear_draft': false,
      },
    });
    _replaceText(
      id,
      text,
      edited: true,
      entities: parsed,
      customEmoji: TDParse.customEmojiEntitiesFrom(parsed),
    );
  }

  Future<void> editMessageCaption(
    int id,
    String caption, {
    List<Map<String, dynamic>> entities = const [],
  }) async {
    await _client.query({
      '@type': 'editMessageCaption',
      'chat_id': chatId,
      'message_id': id,
      'caption': {
        '@type': 'formattedText',
        'text': caption,
        if (entities.isNotEmpty) 'entities': entities,
      },
    });
    _replaceText(
      id,
      caption,
      edited: true,
      entities: TDParse.textEntities({
        '@type': 'formattedText',
        'text': caption,
        'entities': entities,
      }),
      customEmoji: TDParse.customEmojiEntitiesFrom(
        TDParse.textEntities({
          '@type': 'formattedText',
          'text': caption,
          'entities': entities,
        }),
      ),
    );
  }

  Future<void> editMessageMedia(
    int id,
    OutgoingAttachment attachment, {
    required String caption,
    List<Map<String, dynamic>> entities = const [],
  }) async {
    attachment = await fitPhotoToTelegramLimits(attachment);
    await _client.query({
      '@type': 'editMessageMedia',
      'chat_id': chatId,
      'message_id': id,
      'input_message_content': attachmentInputMessageContent(
        attachment,
        caption: caption,
        captionEntities: entities,
      ),
    });
  }

  // MARK: - Paging

  /// Loads a bounded, read-only slice of older messages for an AI reply.
  ///
  /// Unlike [loadOlder] and [loadAroundMessage], this never merges messages
  /// into the transcript, moves the history window, or marks anything read.
  /// The TDLib client is captured with the view model so an account switch
  /// can't redirect a colliding chat id to another account while the request
  /// is in flight. [beforeMessageId] is an exclusive cursor; zero starts from
  /// the latest message available to TDLib.
  Future<AiReplyChatHistoryPage> loadAiReplyContext({
    required int beforeMessageId,
    required String query,
    required int limit,
  }) async {
    _requireAiReplyContextAccess();
    final blockedSenderKeys = await _aiReplyBlockedSenderKeys();
    _requireAiReplyContextAccess();

    final boundedBeforeMessageId = math.max(0, beforeMessageId);
    final boundedLimit = math.min(
      _maximumAiReplyContextMessages,
      math.max(1, limit),
    );
    // TDLib includes from_message_id at offset zero. Ask for one extra item so
    // an exclusive cursor can still return the requested number of messages.
    final requestLimit = boundedBeforeMessageId > 0
        ? boundedLimit + 1
        : boundedLimit;
    final boundedQuery = _boundedAiReplySearchQuery(query);
    final request = boundedQuery.isEmpty
        ? <String, dynamic>{
            '@type': 'getChatHistory',
            'chat_id': chatId,
            'from_message_id': boundedBeforeMessageId,
            'offset': 0,
            'limit': requestLimit,
            'only_local': false,
          }
        : <String, dynamic>{
            '@type': 'searchChatMessages',
            'chat_id': chatId,
            'query': boundedQuery,
            'sender_id': null,
            'from_message_id': boundedBeforeMessageId,
            'offset': 0,
            'limit': requestLimit,
            'filter': {'@type': 'searchMessagesFilterEmpty'},
          };

    final Map<String, dynamic> response;
    try {
      response = await _client.queryTo(
        _scopedHistoryRequest(request),
        _accountClientId,
      );
    } catch (_) {
      _requireAiReplyContextAccess();
      return AiReplyChatHistoryPage(
        messages: const [],
        hasMore: true,
        blockedSenderKeys: blockedSenderKeys,
      );
    }
    _requireAiReplyContextAccess();

    final messagesById = <int, ChatMessage>{};
    final rawMessages =
        response.objects('messages') ?? const <Map<String, dynamic>>[];
    for (final raw in rawMessages) {
      final message = _parseMessage(raw);
      if (message == null ||
          message.id <= 0 ||
          (message.chatId != null && message.chatId != chatId) ||
          (boundedBeforeMessageId > 0 &&
              message.id >= boundedBeforeMessageId) ||
          !_canShareMessageWithAi(message, blockedSenderKeys)) {
        continue;
      }
      _hydrateAiReplySenderName(message);
      messagesById[message.id] = message;
      if (messagesById.length >= boundedLimit) break;
    }

    final result = messagesById.values.toList()
      ..sort(compareChatMessagesChronologically);
    final searchNextMessageId = response.int64('next_from_message_id');
    // TDLib may return fewer messages than requested without reaching the
    // beginning of chat history. Search responses expose an explicit cursor;
    // plain history does not, so only an empty page proves exhaustion there.
    final hasMore = boundedQuery.isNotEmpty
        ? searchNextMessageId == null
              ? rawMessages.isNotEmpty
              : searchNextMessageId != 0
        : rawMessages.isNotEmpty;
    return AiReplyChatHistoryPage(
      messages: List.unmodifiable(result),
      hasMore: hasMore,
      blockedSenderKeys: blockedSenderKeys,
    );
  }

  bool get _canLoadAiReplyContext =>
      !_isDisposed &&
      !isSecretChat &&
      !hasProtectedContent &&
      _accountClientId > 0 &&
      _client.activeClientId == _accountClientId &&
      _client.activeSlot == _accountSlot;

  bool get canShareAiReplyContext => _canLoadAiReplyContext;

  /// True when the last bulk read lost some topics; the surface reads and
  /// clears it to raise one toast.
  bool _bulkReadFailed = false;

  static String _primaryUsername(Map<String, dynamic> user) {
    final usernames = user.obj('usernames');
    final active = usernames?['active_usernames'];
    if (active is List) {
      for (final value in active) {
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }
    final editable = usernames?.str('editable_username')?.trim();
    if (editable != null && editable.isNotEmpty) return editable;
    return (user.str('username') ?? '').trim();
  }

  static const _pinnedDismissalPrefix = 'mithka.pinnedBarDismissal.v1.user';

  bool get hasPreviousPinnedMessage => pinnedMessageIndex > 0;

  bool get hasNextPinnedMessage =>
      pinnedMessageIndex < pinnedMessages.length - 1;

  // MARK: - Live updates

  /// Every `@type` [_handle] has an arm for. Keep in sync with its switch: an
  /// omission silently stops that arm from ever running.
  static const _handledUpdateTypes = <String>[
    'updateNewMessage',
    'updateMessageContent',
    'updateMessageSuggestedPostInfo',
    'updateChatUnreadMentionCount',
    'updateMessageMentionRead',
    'updateChatUnreadReactionCount',
    'updateMessageUnreadReactions',
    'updateMessageSendSucceeded',
    'updateMessageSendAcknowledged',
    'updateMessageSendFailed',
    'updateSecretChat',
    'updateChat',
    'updateChatActionBar',
    'updateChatBusinessBotManageBar',
    'updateChatHasProtectedContent',
    'updateChatDraftMessage',
    'updateForumTopic',
    'updateForumTopicInfo',
    'updateChatMessageAutoDeleteTime',
    'updateChatPaidMessageStarCount',
    'updateDeleteMessages',
    'mithkaChatHistoryCleared',
    'mithkaChatLeft',
    'updateChatReadOutbox',
    'updateChatReadInbox',
    'updateChatIsMarkedAsUnread',
    'updateChatAction',
    'updateChatMessageSender',
    'updateUser',
    'updateUserFullInfo',
    'updateSupergroup',
    'updateSupergroupFullInfo',
    'updateBasicGroupFullInfo',
    'updateUserStatus',
    'updateMessageEdited',
    'updateMessageInteractionInfo',
    'updateMessageIsPinned',
    'updateAvailableMessageEffects',
    'updateBlockMessageSender',
  ];

  // MARK: - Reactions

  bool get _usesBotApiBackend =>
      isBotApiAccount || _client.isBotApiSlot(_accountSlot);

  /// True while the client this pane was opened on is still the active one.
  /// Destructive actions confirmed through a dialog re-check this after the
  /// await so the write cannot land on a replacement account.
  bool get isAccountCurrent =>
      !_isDisposed &&
      _accountClientId > 0 &&
      _client.activeClientId == _accountClientId &&
      _client.activeSlot == _accountSlot;

  /// Per-message action availability from `messageProperties`: whether a
  /// shareable link exists (`can_get_link`), whether Telegram accepts a reply
  /// in this chat (`can_be_replied`) and whether THIS account may delete the
  /// message (`can_be_deleted_only_for_self` / `can_be_deleted_for_all_users`).
  /// All of them live only on the server object, so one query answers the
  /// menu; a property error propagates and the caller keeps the entries
  /// hidden, which is exactly what the reference client's
  /// `MessageObject.canDeleteForAll` gate answers.
  Future<({bool canGetLink, bool canBeReplied, bool canDelete})>
  messageActionAvailability(int messageId) async {
    final properties = await _client.queryTo({
      '@type': 'getMessageProperties',
      'chat_id': chatId,
      'message_id': messageId,
    }, _accountClientId);
    return (
      canGetLink: properties.boolean('can_get_link') ?? false,
      canBeReplied: properties.boolean('can_be_replied') ?? false,
      canDelete:
          (properties.boolean('can_be_deleted_only_for_self') ?? false) ||
          (properties.boolean('can_be_deleted_for_all_users') ?? false),
    );
  }

  /// Whether the message can be quoted-replied in a different chat
  /// (`messageProperties.can_be_replied_in_another_chat`). Secret chats never
  /// accept an external reply, and a plain sendability check keeps the entry
  /// hidden where the destination composer could not answer anyway.
  Future<bool> canReplyInAnotherChat(ChatMessage message) async {
    if (isSecretChat) return false;
    if (_usesBotApiBackend) return false;
    try {
      final properties = await _client.queryTo({
        '@type': 'getMessageProperties',
        'chat_id': message.chatId ?? chatId,
        'message_id': message.id,
      }, _accountClientId);
      return properties.boolean('can_be_replied_in_another_chat') ?? false;
    } on Object {
      return false;
    }
  }

  /// The HTTPS link TDLib generated for the message. Returns the raw
  /// `messageLink.link`; [getMessageLink] is authoritative for when a link
  /// exists, so a plain error propagates to the action's failure toast.
  Future<String> messageLink(int messageId) async {
    final link = await _client.queryTo({
      '@type': 'getMessageLink',
      'chat_id': chatId,
      'message_id': messageId,
      'media_timestamp': 0,
      'checklist_task_id': 0,
      'poll_option_id': '',
      'for_album': false,
      'in_message_thread': false,
    }, _accountClientId);
    return link.str('link') ?? '';
  }

  Future<void> addReaction(int messageId, String emoji) =>
      _addReactionChoice(messageId, QuickReactionChoice.emoji(emoji));

  /// Custom (premium) emoji reaction.
  Future<void> addCustomReaction(int messageId, int customEmojiId) =>
      _addReactionChoice(messageId, QuickReactionChoice.custom(customEmojiId));

  Future<void> _addReactionChoice(
    int messageId,
    QuickReactionChoice requested,
  ) async {
    final availability = await messageReactionAvailability(messageId);
    final reaction = availability.canonicalChoice(requested);
    if (reaction == null) throw const MessageReactionUnavailableException();
    await _sendReactionChoice(messageId, reaction);
  }

  Future<void> _sendReactionChoice(
    int messageId,
    QuickReactionChoice reaction,
  ) async {
    await _client.queryTo({
      '@type': 'addMessageReaction',
      'chat_id': chatId,
      'message_id': messageId,
      'reaction_type': reaction.isCustom
          ? {
              '@type': 'reactionTypeCustomEmoji',
              'custom_emoji_id': reaction.customEmojiId,
            }
          : {'@type': 'reactionTypeEmoji', 'emoji': reaction.emoji},
      'is_big': false,
      'update_recent_reactions': true,
    }, _accountClientId);
  }

  Future<void> toggleReaction(ChatMessage m, MessageReaction r) async {
    if (r.chosen) {
      // TDLib guarantees that a chosen reaction remains removable even when
      // the user can no longer add reactions to the message.
      await _client.queryTo({
        '@type': 'removeMessageReaction',
        'chat_id': chatId,
        'message_id': m.id,
        'reaction_type': r.type,
      }, _accountClientId);
    } else {
      final reaction = r.customEmojiId != 0
          ? QuickReactionChoice.custom(r.customEmojiId)
          : QuickReactionChoice.emoji(r.emoji ?? '');
      if (_usesBotApiBackend) {
        // A Bot API message can expose a reaction bucket even though the API
        // can't enumerate all reactions allowed for that individual message.
        // Let the server accept or reject that exact existing bucket.
        await _sendReactionChoice(m.id, reaction);
      } else {
        await _addReactionChoice(m.id, reaction);
      }
    }
  }

  Future<List<MessageReactionUser>> reactionUsers(
    ChatMessage message,
    MessageReaction reaction,
  ) async {
    final res = await _client.query({
      '@type': 'getMessageAddedReactions',
      'chat_id': chatId,
      'message_id': message.id,
      'reaction_type': reaction.type,
      'offset': '',
      'limit': 100,
    });
    final added = res.objects('reactions') ?? const <Map<String, dynamic>>[];
    final users = <MessageReactionUser>[];
    for (final item in added) {
      final senderId = _senderIdFromTd(item.obj('sender_id'));
      if (senderId == null) continue;
      final info = await _reactionSenderInfo(senderId);
      users.add(
        MessageReactionUser(
          senderId: senderId,
          title: info.name,
          photo: info.photo,
          date: item.integer('date') ?? 0,
          isDeleted: info.isDeleted,
        ),
      );
    }
    return users;
  }

  int? _senderIdFromTd(Map<String, dynamic>? sender) {
    return switch (sender?.type) {
      'messageSenderUser' => sender?.int64('user_id'),
      'messageSenderChat' => sender?.int64('chat_id'),
      _ => null,
    };
  }

  Future<_SenderInfo> _reactionSenderInfo(int senderId) async {
    final cached = _senderCache[senderId];
    if (cached != null) return cached;
    if (senderId > 0) {
      try {
        final user = await _client.query({
          '@type': 'getUser',
          'user_id': senderId,
        });
        return _SenderInfo(
          TDParse.userName(user),
          TDParse.smallPhoto(user.obj('profile_photo')),
          MemberRole.member,
          null,
          isDeleted: TDParse.isDeletedUser(user),
        );
      } catch (_) {
        return _SenderInfo(
          AppStrings.t(AppStringKeys.chatUserFallbackName, {
            'value1': senderId,
          }),
          null,
          MemberRole.member,
          null,
        );
      }
    }
    try {
      final chat = await _client.query({
        '@type': 'getChat',
        'chat_id': senderId,
      });
      return _SenderInfo(
        chat.str('title') ?? AppStrings.t(AppStringKeys.chatInfoGroupMembers),
        TDParse.smallPhoto(chat.obj('photo')),
        MemberRole.member,
        null,
      );
    } catch (_) {
      return _SenderInfo(
        AppStrings.t(AppStringKeys.chatInfoGroupMembers),
        null,
        MemberRole.member,
        null,
      );
    }
  }

  void _restartTypingTimer() {
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 6), () {
      if (_chatActions.isNotEmpty) {
        _chatActions.clear();
        _notifyComposerNeutral();
      }
    });
  }

  String get _chatActionSubtitle {
    if (_chatActions.isEmpty) return '';
    final actions = _chatActions.values.toList(growable: false);
    if (actions.length > 1) {
      final allTyping = actions.every(
        (a) => a.actionType == 'chatActionTyping',
      );
      return AppStrings.t(
        allTyping
            ? AppStringKeys.chatPeopleTyping
            : AppStringKeys.chatPeopleDoingAction,
        {'value1': actions.length},
      );
    }

    final action = actions.first;
    final label = _chatActionLabel(action.actionType);
    if (!isGroup) return label;
    final name = action.name.trim();
    if (name.isEmpty) return label;
    if (action.actionType == 'chatActionTyping') {
      return AppStrings.t(AppStringKeys.chatUserTyping, {'value1': name});
    }
    return AppStrings.t(AppStringKeys.chatUserDoingAction, {
      'value1': name,
      'value2': label,
    });
  }

  String _chatActionLabel(String type) {
    switch (type) {
      case 'chatActionRecordingVideo':
        return AppStrings.t(AppStringKeys.chatActionRecordingVideo);
      case 'chatActionUploadingVideo':
        return AppStrings.t(AppStringKeys.chatActionUploadingVideo);
      case 'chatActionRecordingVoiceNote':
        return AppStrings.t(AppStringKeys.chatActionRecordingVoice);
      case 'chatActionUploadingVoiceNote':
        return AppStrings.t(AppStringKeys.chatActionUploadingVoice);
      case 'chatActionUploadingPhoto':
        return AppStrings.t(AppStringKeys.chatActionUploadingPhoto);
      case 'chatActionUploadingDocument':
        return AppStrings.t(AppStringKeys.chatActionUploadingFile);
      case 'chatActionChoosingSticker':
        return AppStrings.t(AppStringKeys.chatActionChoosingSticker);
      case 'chatActionChoosingLocation':
        return AppStrings.t(AppStringKeys.chatActionChoosingLocation);
      case 'chatActionChoosingContact':
        return AppStrings.t(AppStringKeys.chatActionChoosingContact);
      case 'chatActionStartPlayingGame':
        return AppStrings.t(AppStringKeys.chatActionPlayingGame);
      case 'chatActionRecordingVideoNote':
        return AppStrings.t(AppStringKeys.chatActionRecordingVideoNote);
      case 'chatActionUploadingVideoNote':
        return AppStrings.t(AppStringKeys.chatActionUploadingVideoNote);
      case 'chatActionWatchingAnimations':
        return AppStrings.t(AppStringKeys.chatActionWatchingAnimations);
      case 'chatActionTyping':
      default:
        return AppStrings.t(AppStringKeys.chatTyping);
    }
  }

  /// For each message that replies to another, resolve the quoted sender +
  /// preview — from the already-loaded list when possible, else via getMessages.
  void _resolveRepliesIfNeeded(List<ChatMessage> batch) {
    final repliesToResolve = batch
        .where(
          (message) =>
              message.replyToMessageId != null &&
              message.replyToPreview == null,
        )
        .toList(growable: false);
    if (repliesToResolve.isEmpty) return;
    // This index is already maintained by transcript mutations. Rebuilding a
    // map for each history page (or scanning the transcript for a live reply)
    // made quoting increasingly expensive as more history was loaded.
    _ensureMessageIndexes();
    final unresolvedByChat = <int, Map<int, List<ChatMessage>>>{};
    for (final m in repliesToResolve) {
      final rid = m.replyToMessageId!;
      final rChatId = m.replyToChatId ?? m.chatId ?? chatId;
      final quoted = rChatId == chatId
          ? (_messagesById[rid] ?? _allMessagesById[rid])
          : null;
      if (quoted != null) {
        // The locally cached target is trusted only across the restriction
        // boundary: a redacted message must not lend its text to this anchor,
        // and no remote lookup can repair the hole it would leave.
        if (!quoted.isContentRestricted) {
          _applyReply(m, quoted);
        }
        continue;
      }
      // Reply-to-deleted fill: when the target is not in
      // the transcript, the local mirror may still hold a kept copy of the
      // deleted original; its text fills the reply anchor like a quote.
      if (_applyMirrorReply(m, rid, rChatId)) {
        continue;
      }
      final unresolved = unresolvedByChat.putIfAbsent(
        rChatId,
        () => <int, List<ChatMessage>>{},
      );
      unresolved.putIfAbsent(rid, () => <ChatMessage>[]).add(m);
    }
    if (unresolvedByChat.isEmpty) return;
    // One getMessage per distinct target meant 10-25 concurrent round trips for
    // a single reply-heavy history page, repeated for every page scrolled up.
    // getMessages answers them all at once, so the previews fill in together.
    for (final entry in unresolvedByChat.entries) {
      final targetChatId = entry.key;
      final unresolved = entry.value;
      final targets = unresolved.keys.toList();
      for (var start = 0; start < targets.length; start += 100) {
        final end = start + 100 > targets.length ? targets.length : start + 100;
        _resolveReplyTargets(
          targetChatId,
          targets.sublist(start, end),
          unresolved,
        );
      }
    }
  }

  /// Fills a reply anchor from the mirror when the quoted message was
  /// deleted (Telegram §1.4, self-build gated): the kept copy's text,
  /// sender and date become the quote-style preview. Only used when the
  /// live transcript does not have the target — a live message always wins.
  bool _applyMirrorReply(ChatMessage m, int replyId, int replyChatId) {
    if (!allowTelegramTosViolations) return false;
    final store = historyStoreOverride ?? MessageHistoryStore.shared;
    final accountUserId = _accountUserId;
    if (accountUserId == null) return false;
    final entry = store.entryFor(accountUserId, replyChatId, replyId);
    if (entry == null) return false;
    // Only the plain fallback preview takes the mirror text — a real quote
    // (replyToQuote, an explicit quote of part of the original) keeps its
    // own stored excerpt, which stays more truthful than the whole copy.
    if (m.replyToQuote != null) return true;
    final body = entry.text.trim().isNotEmpty
        ? entry.text.trim()
        : localizedHistoryKindLabelStub(entry.kindKey);
    m.replyToPreview = body;
    m.replyToDate = entry.date;
    if (entry.senderId != 0) {
      final info = _senderCache[entry.senderId];
      m.replyToSender = info?.name ?? '';
      m.replyToSenderAccentColorId = info?.accentColorId ?? -1;
      m.replyToSenderEmojiStatusId = info?.emojiStatusId ?? 0;
      m.replyToSenderIsPremium = info?.isPremium ?? false;
      if ((m.replyToSender ?? '').isEmpty && entry.senderId > 0) {
        unawaited(_resolveQuotedSender(m, entry.senderId));
      }
    } else {
      m.replyToSender = isGroup ? '' : peerTitle;
    }
    return true;
  }

  /// The account whose mirror this transcript reads (via
  /// [accountSummaryProvider]), exposed for surfaces that outlive the view
  /// model's own lookups (the message info sheet's mirror row).
  int? get mirrorAccountUserId => _accountUserId;

  /// The mirror's kept copy behind one message addressed by THIS
  /// transcript, looked up under the slot that owns this transcript — not
  /// whichever account is currently active. Long-press actions (view
  /// edits) and the message info sheet read through here, so a stale pane
  /// after an account switch never shows (or fails to find) another
  /// account's mirror row. [message] may carry its own chat id (a
  /// forwarded or quoted target lives in another chat); the transcript's
  /// chat is the fallback.
  MessageHistoryEntry? mirrorEntryForMessage(ChatMessage message) {
    if (!allowTelegramTosViolations) return null;
    final accountUserId = _accountUserId;
    if (accountUserId == null) return null;
    final targetChatId = message.chatId ?? chatId;
    return (historyStoreOverride ?? MessageHistoryStore.shared).entryFor(
      accountUserId,
      targetChatId,
      message.id,
    );
  }

  /// Localized kind label without a BuildContext (AppStrings reads the
  /// ambient locale); a media-only kept copy shows this instead of its
  /// empty text. Falls back to the raw suffix when the key is unknown.
  static String localizedHistoryKindLabelStub(String kindKey) {
    if (kindKey.isEmpty) return '';
    final key = switch (kindKey) {
      'historyKindPhoto' => AppStringKeys.historyKindPhoto,
      'historyKindVideo' => AppStringKeys.historyKindVideo,
      'historyKindVideoNote' => AppStringKeys.historyKindVideoNote,
      'historyKindVoice' => AppStringKeys.historyKindVoice,
      'historyKindAnimation' => AppStringKeys.historyKindAnimation,
      'historyKindSticker' => AppStringKeys.historyKindSticker,
      'historyKindDocument' => AppStringKeys.historyKindDocument,
      'historyKindAudio' => AppStringKeys.historyKindAudio,
      'historyKindPoll' => AppStringKeys.historyKindPoll,
      'historyKindLocation' => AppStringKeys.historyKindLocation,
      'historyKindContact' => AppStringKeys.historyKindContact,
      'historyKindDice' => AppStringKeys.historyKindDice,
      _ => AppStringKeys.historyKindUnknown,
    };
    final label = AppStrings.t(key);
    return label.isEmpty ? kindKey : label;
  }

  /// Fetches one batch of reply targets and patches every message waiting on it.
  void _resolveReplyTargets(
    int targetChatId,
    List<int> messageIds,
    Map<int, List<ChatMessage>> unresolved,
  ) {
    _client
        .query({
          '@type': 'getMessages',
          'chat_id': targetChatId,
          'message_ids': messageIds,
        })
        .then((response) {
          if (_chatOpenWorkIsStale) return;
          final updatedIds = <int>{};
          // Unavailable ids come back as nulls that carry no identity, so the
          // bucket is looked up by the id on each returned message, not by
          // position.
          final raws =
              response.objects('messages') ?? const <Map<String, dynamic>>[];
          for (final raw in raws) {
            final quoted = _parseMessage(raw);
            if (quoted == null) continue;
            final waiting = unresolved[quoted.id];
            if (waiting == null) continue;
            for (final m in waiting) {
              final refs = _messageRefs(m.id);
              final targets = refs.isEmpty ? <ChatMessage>[m] : refs;
              for (final message in targets) {
                // A held lookup belongs to the COMPLETE target captured when it
                // was issued. The message id alone is not identity: the refresh
                // may have retargeted this very reply to another chat that uses
                // the same numeric id, and applying the old chat's payload
                // would hydrate the new target with another message's text.
                final liveChatId =
                    message.replyToChatId ?? message.chatId ?? chatId;
                if (message.replyToMessageId != quoted.id ||
                    liveChatId != targetChatId ||
                    message.replyToPreview != null) {
                  continue;
                }
                // Returned quotes must come from the requested chat: a
                // mis-addressed response would otherwise smuggle a same-id
                // message of a foreign chat into the reply anchor.
                final quotedChatId = quoted.chatId ?? targetChatId;
                if (quotedChatId != targetChatId) continue;
                // A restriction-redacted reply must never be hydrated from
                // cached quote plaintext, and a redacted response is a
                // withdrawal, not an anchor to copy.
                if (message.isContentRestricted || quoted.isContentRestricted) {
                  continue;
                }
                _applyReply(message, quoted);
                updatedIds.add(message.id);
              }
            }
          }
          if (updatedIds.isNotEmpty) {
            _bumpMaterializedMessageRevisions(updatedIds);
            _scheduleCoalescedNotify();
          }
        })
        .catchError((_) {});
  }

  void _applyReply(ChatMessage m, ChatMessage quoted) {
    m.replyToPreview = _replyPreview(quoted);
    m.replyToDate = quoted.date;
    m.replyToEntities = quoted.textEntities;
    m.replyToImage = quoted.previewImage;
    m.replyToImageWidth = quoted.imageWidth;
    m.replyToImageHeight = quoted.imageHeight;
    // The marker shows the ORIGINAL author's identity, not this message's.
    m.replyToSenderAccentColorId = quoted.senderAccentColorId;
    m.replyToSenderEmojiStatusId = quoted.senderEmojiStatusId;
    m.replyToSenderIsPremium = quoted.senderIsPremium;
    if (quoted.isOutgoing) {
      m.replyToSender = meName;
      return;
    }
    // Name the actual author of the quoted message — never the chat/group name.
    final name = quoted.senderName;
    if (name != null && name.isNotEmpty) {
      m.replyToSender = name;
      return;
    }
    final sid = quoted.senderId;
    final cached = sid == null ? null : _senderCache[sid];
    if (cached != null) {
      m.replyToSender = cached.name;
    } else if (sid != null) {
      m.replyToSender = ''; // resolve in the background, fill on next render
      _resolveQuotedSender(m, sid);
    } else {
      m.replyToSender = isGroup ? '' : peerTitle;
    }
  }

  /// Resolves a quoted message's author name (user or chat sender) and patches
  /// the reply in place. Reuses the sender cache populated for the transcript.
  Future<void> _resolveQuotedSender(ChatMessage m, int senderId) async {
    final existing = _senderCache[senderId];
    if (existing != null && existing.name.isNotEmpty) {
      m.replyToSender = existing.name;
      _bumpMaterializedMessageRevisions([m.id]);
      _scheduleCoalescedNotify();
      return;
    }
    String? name;
    try {
      if (senderId > 0) {
        final user = await _client.query({
          '@type': 'getUser',
          'user_id': senderId,
        });
        name = TDParse.userName(user);
      } else {
        final chat = await _client.query({
          '@type': 'getChat',
          'chat_id': senderId,
        });
        name = chat.str('title');
      }
    } catch (_) {}
    if (name != null && name.isNotEmpty) {
      m.replyToSender = name;
      _bumpMaterializedMessageRevisions([m.id]);
      _scheduleCoalescedNotify();
    }
  }

  String _replyPreview(ChatMessage q) {
    if (q.document != null) {
      return AppStrings.t(AppStringKeys.composerFilePreview, {
        'value1': q.document!.fileName,
      });
    }
    if (q.voice != null) {
      return AppStrings.t(AppStringKeys.composerVoicePreview);
    }
    if (q.location != null) {
      return AppStrings.t(AppStringKeys.composerLocationPreview);
    }
    if (q.isDice) {
      return q.diceEmoji ?? q.text;
    }
    if (q.isAnimatedEmoji) {
      return q.text;
    }
    if (q.animatedSticker != null) {
      return AppStrings.t(AppStringKeys.composerAnimatedEmojiPreview);
    }
    if (q.image != null) {
      final placeholder = switch (q.contentType) {
        'messagePhoto' => AppStrings.t(AppStringKeys.composerImagePreview),
        'messageVideo' => AppStrings.t(AppStringKeys.chatVideoPlaceholder),
        'messageAnimation' => AppStrings.t(AppStringKeys.tdMessageGif),
        _ => null,
      };
      return q.text == placeholder ? '' : q.text;
    }
    return q.text;
  }

  // MARK: - Merge / mutate

  bool _isBlockedMessage(ChatMessage message) {
    if (message.isOutgoing || message.isService) return false;
    final senderId = message.senderId;
    if (senderId != null && _blockedSenderIds.contains(senderId)) return true;
    if (KeywordBlocker.shared.isSenderBlocked(senderId)) return true;
    if (HiddenSenderStore.shared.hides(senderId, chatId)) return true;
    return KeywordBlocker.shared.matches(message.text);
  }

  // ---------------------------------------------------------------------------
  // Ghost transcript (Telegram §1.4 mirror, self-build gated)
  // ---------------------------------------------------------------------------

  /// Whether ghost bubbles may render in this transcript. Ghosts are a
  /// render-only layer: the switches live in settings, the data in the
  /// mirror store, and neither touches TDLib traffic.
  bool get _ghostsEnabled =>
      allowTelegramTosViolations && MessageHistorySettings.shared.renderGhosts;

  /// The owning account's user id for this transcript's slot. Ghost folding
  /// is sync-only (it runs inside every transcript rebuild), so the id comes
  /// from the app's cached account summaries via the injected bridge —
  /// production wires it in main, tests inject their own.
  int? get _accountUserId => accountSummaryProvider?.call(_accountSlot)?.userId;

  /// Slot → account summary bridge (production: the app's AccountStore).
  static AccountSummaryForSlot? accountSummaryProvider;

  /// Deleted mirror entries of this chat become in-place ghost bubbles; the
  /// ids not present in the transcript are the ghosts to fold in. A topic
  /// transcript folds only its own topic's ghosts.
  List<MessageHistoryEntry> _ghostEntriesForTranscript() {
    if (!_ghostsEnabled) return const [];
    final accountUserId = _accountUserId;
    if (accountUserId == null) return const [];
    return (historyStoreOverride ?? MessageHistoryStore.shared)
        .deletedEntriesFor(accountUserId, chatId, topicId: forumTopicId ?? 0);
  }

  /// Once per open, asks the server whether the chat's kept "deleted" copies
  /// still exist. A copy wrongly marked deleted — older builds recorded
  /// TDLib's cache-unload updates as deletions — gets no live update to
  /// contradict it, so without this probe its ghost would stay in the
  /// transcript forever. `getMessages` is the ground truth: ids the server
  /// still returns are live messages and are reactivated in the mirror.
  Future<void> _reconcileMirrorGhosts() async {
    if (!allowTelegramTosViolations || _mirrorGhostsReconciled) return;
    final accountUserId = _accountUserId;
    if (accountUserId == null) return;
    final store = historyStoreOverride ?? MessageHistoryStore.shared;
    final ghosts = store.deletedEntriesFor(
      accountUserId,
      chatId,
      topicId: forumTopicId ?? 0,
    );
    if (ghosts.isEmpty) {
      // A cold start can open a chat before the mirror file is read; an
      // empty answer is only final once it has landed.
      if (store.isLoaded) _mirrorGhostsReconciled = true;
      return;
    }
    _mirrorGhostsReconciled = true;
    // Bound the probe to the newest copies: they are what a session can
    // scroll to, and 100 ids per call is TDLib's usual batch size.
    final ids = [for (final entry in ghosts) entry.messageId]
      ..sort((a, b) => b.compareTo(a));
    final bounded = ids.take(200).toList(growable: false);
    for (var start = 0; start < bounded.length; start += 100) {
      if (_chatOpenWorkIsStale) return;
      final end = math.min(start + 100, bounded.length);
      final chunk = bounded.sublist(start, end);
      Map<String, dynamic> response;
      try {
        response = await _client.queryTo({
          '@type': 'getMessages',
          'chat_id': chatId,
          'message_ids': chunk,
        }, _accountClientId);
      } catch (_) {
        return; // offline: the new deletion rule still keeps fresh data clean
      }
      if (_chatOpenWorkIsStale) return;
      for (final raw
          in response.objects('messages') ?? const <Map<String, dynamic>>[]) {
        final id = raw.integer('id') ?? 0;
        if (id <= 0) continue;
        final rawChatId = raw.int64('chat_id');
        if (rawChatId != null && rawChatId != chatId) continue;
        store.confirmAlive(accountUserId, chatId, id);
      }
    }
  }

  bool _mirrorGhostsReconciled = false;

  /// Folds ghost bubbles into the published transcript after every rebuild.
  /// Ghosts are render-only: they join `messages` (sorted by their original
  /// message id, so they sit where the message used to be) but never enter
  /// `_allMessages` or any id index — the id no longer exists on Telegram's
  /// side, so read states, mentions and merges must not see it.
  void _foldGhostsIntoTranscript() {
    if (!_ghostsEnabled) return;
    final entries = _ghostEntriesForTranscript();
    final inTranscript = _allMessages.map((m) => m.id).toSet();
    final accountUserId = _accountUserId;
    final ghosts = <ChatMessage>[];
    for (final entry in entries) {
      if (inTranscript.contains(entry.messageId)) continue;
      ghosts.add(_ghostChatMessageFor(entry, accountUserId));
    }
    // Ghost ids no longer exist on Telegram's side, so a ghost never shows up
    // in a history batch and its sender would stay unresolved: no name, no
    // avatar photo. Resolve them like any other incoming message; the async
    // results patch the folded bubbles through _patchSenders. Ghosts folded by
    // an earlier pass are covered too — they are no longer in `ghosts`, but
    // their sender may still be resolving.
    final knownGhosts = messages.where((m) => m.mirrorEntry != null);
    _resolveSendersIfNeeded([...ghosts, ...knownGhosts]);
    if (ghosts.isEmpty) return;
    messages = mergeChatMessages(messages, ghosts);
  }

  /// One ghost as a transcript [ChatMessage]. `contentType` marks the ghost
  /// for the bubble layer; media ghosts carry their snapshot through
  /// [ChatMessage.mirrorEntry]. A kept media copy with a snapshot renders the
  /// actual image/file in the bubble, so its text stays the CAPTION (empty
  /// when none) instead of the kind label — otherwise the label would print
  /// under the media it names.
  ChatMessage _ghostChatMessageFor(
    MessageHistoryEntry entry,
    int? accountUserId,
  ) {
    final senderId = entry.senderId == 0 ? null : entry.senderId;
    final isOutgoing = accountUserId != null && entry.senderId == accountUserId;
    final hasMedia = entry.mediaPath.isNotEmpty;
    final caption = entry.text.trim();
    final sender = senderId == null ? null : _senderCache[senderId];
    return ChatMessage(
      id: entry.messageId,
      isOutgoing: isOutgoing,
      // Media-only kept copies without a snapshot have no text; the localized
      // kind label keeps the ghost bubble from rendering as an empty shell.
      text: caption.isNotEmpty
          ? entry.text
          : hasMedia
          ? ''
          : localizedHistoryKindLabelStub(entry.kindKey),
      date: entry.date,
      chatId: chatId,
      senderId: senderId,
      contentType: 'mithkaGhost',
      // Attribution: a group ghost renders the sender header and avatar like
      // any kept message would. The name/photo come from the sender cache the
      // fold primed above; _patchSenders refreshes them when the async lookup
      // lands. A chat-sent ghost (negative id) avatars as that chat.
      senderName: isOutgoing
          ? (meName.trim().isNotEmpty ? meName : null)
          : sender?.name,
      senderPhoto: sender?.photo,
      senderIsChat: senderId != null && senderId < 0,
      senderRole: sender?.role,
      senderTitle: sender?.title,
      senderIsPremium: sender?.isPremium ?? false,
      senderIsDeleted: sender?.isDeleted ?? false,
      senderAccentColorId: sender?.accentColorId ?? -1,
      senderEmojiStatusId: sender?.emojiStatusId ?? 0,
      senderPresence: sender?.presence ?? AvatarPresence.none,
    )..mirrorEntry = entry;
  }

  /// Test seam: run the transcript rebuild (and with it the ghost fold)
  /// without driving TDLib.
  @visibleForTesting
  void debugRebuildTranscriptForTesting() => _applyKeywordFilter();

  /// Test seam: run the once-per-open ghost reconciliation without the full
  /// chat-open task.
  @visibleForTesting
  Future<void> debugReconcileMirrorGhostsForTesting() =>
      _reconcileMirrorGhosts();

  /// Test seam: merge live messages as the update path would.
  @visibleForTesting
  void debugMergeMessagesForTesting(List<ChatMessage> incoming) {
    _merge(incoming);
    _resolveRepliesIfNeeded(incoming);
  }

  /// Test seam: ids currently in `_allMessages` (ghosts never join it).
  @visibleForTesting
  Iterable<int> debugAllMessageIdsForTesting() => _allMessages.map((m) => m.id);

  /// Settings and mirror flips re-fold the transcript: turning ghosts off
  /// must remove them, a new deletion must insert one.
  void _onGhostSourceChanged() {
    if (_isDisposed) return;
    _applyKeywordFilter();
    if (!_mirrorGhostsReconciled) {
      unawaited(_reconcileMirrorGhosts());
    }
  }

  /// Rebuilds `messages` from `_allMessages` and refreshes the lookup indexes.
  ///
  /// One pass does the filtering, the blocked-user marking and the index fill
  /// that used to cost four separate walks plus a sort. `_allMessages` is kept
  /// sorted by every writer, so re-sorting the filtered subsequence here was
  /// pure cost on every incoming message.
  void _applyKeywordFilter() {
    // The chat_view transcript memo relies on list identity to notice
    // blocked-state changes, so the flags must be set before `messages` is
    // published — never flip them outside this pass.
    final blockedUserService = BlockedUserService.shared;
    final marksBlockedUsers = blockedUserService.enabled;
    _marksBlockedUsers = marksBlockedUsers;
    final visible = <ChatMessage>[];
    final blockedIds = <int>[];
    _messagesById.clear();
    _allMessagesById.clear();
    _messagesBySenderId.clear();
    _pendingMessageCount = 0;
    for (final message in _allMessages) {
      assert(_recordTranscriptScanVisitForTesting());
      _allMessagesById[message.id] = message;
      if (isPendingChatMessage(message)) ++_pendingMessageCount;
      if (_isBlockedMessage(message)) {
        blockedIds.add(message.id);
        continue;
      }
      final senderId = message.senderId;
      message.blockedByUser =
          marksBlockedUsers &&
          !message.isOutgoing &&
          !message.isService &&
          senderId != null &&
          blockedUserService.isBlocked(senderId);
      visible.add(message);
      _messagesById[message.id] = message;
      if (senderId != null) {
        (_messagesBySenderId[senderId] ??= <ChatMessage>[]).add(message);
      }
    }
    _messageIndexesDirty = false;
    // Guards the dropped sort. With a pending send in the list the comparator
    // is not a total order, so only the pure-id case can be checked.
    assert(_pendingMessageCount > 0 || _isSortedById(_allMessages));
    messages = visible;
    _foldGhostsIntoTranscript();
    _blockedMessageIds = blockedIds;
    _markBlockedMessagesReadThroughVisibleBoundary(blockedIds);
    notifyListeners();
  }

  // State the incremental append path needs to stay equivalent to the full
  // pass: what `blockedByUser` was last computed against, and every blocked id
  // in `_allMessages` (the read-boundary marker is handed the whole set each
  // time, because an arrival can move the boundary past an older blocked one).
  bool _marksBlockedUsers = false;

  List<int> _blockedMessageIds = <int>[];

  /// Folds one strictly-newest message into the published transcript without
  /// the whole-transcript rebuild [_applyKeywordFilter] does.
  ///
  /// That rebuild walked every loaded message and refilled three indexes per
  /// arrival, so a chat got measurably slower the further back the user had
  /// scrolled — thousands of blocked checks and map inserts for one message.
  void _appendToVisibleTranscript(ChatMessage message) {
    final blockedUserService = BlockedUserService.shared;
    // The full pass re-evaluates blockedByUser for the whole transcript. The
    // other inputs to it announce themselves (KeywordBlocker notifies,
    // updateBlockMessageSender reloads), but this toggle does not, so a change
    // has to fall back.
    if (blockedUserService.enabled != _marksBlockedUsers) {
      _applyKeywordFilter();
      return;
    }
    // Guaranteed by _appendIfStrictlyNewest, so the pending count cannot move.
    assert(!isPendingChatMessage(message));
    // A revived message (the same id as a folded ghost re-entering the
    // transcript) must retire its ghost through the full rebuild — the fast
    // path would leave both the ghost and the live copy on screen.
    if (_ghostsEnabled) {
      final accountUserId = _accountUserId;
      final revivedGhost =
          accountUserId != null &&
          (historyStoreOverride ?? MessageHistoryStore.shared)
              .deletedEntriesFor(
                accountUserId,
                chatId,
                topicId: forumTopicId ?? 0,
              )
              .any((entry) => entry.messageId == message.id);
      if (revivedGhost) {
        _applyKeywordFilter();
        return;
      }
    }
    _allMessagesById[message.id] = message;
    if (_isBlockedMessage(message)) {
      _blockedMessageIds.add(message.id);
    } else {
      final senderId = message.senderId;
      message.blockedByUser =
          _marksBlockedUsers &&
          !message.isOutgoing &&
          !message.isService &&
          senderId != null &&
          blockedUserService.isBlocked(senderId);
      // Reassigned, never mutated: chat_view's transcript memo keys on the
      // list's identity.
      messages = [...messages, message];
      _messagesById[message.id] = message;
      if (senderId != null) {
        (_messagesBySenderId[senderId] ??= <ChatMessage>[]).add(message);
      }
    }
    _messageIndexesDirty = false;
    _markBlockedMessagesReadThroughVisibleBoundary(_blockedMessageIds);
    notifyListeners();
  }

  bool _isSortedById(List<ChatMessage> list) {
    for (var i = 1; i < list.length; i++) {
      if (list[i - 1].id > list[i].id) return false;
    }
    return true;
  }

  /// Refreshes the lookup indexes after a caller mutated either list without
  /// going through `_applyKeywordFilter`.
  void _ensureMessageIndexes() {
    if (!_messageIndexesDirty) return;
    _messagesById.clear();
    _allMessagesById.clear();
    _messagesBySenderId.clear();
    _pendingMessageCount = 0;
    for (final message in _allMessages) {
      assert(_recordTranscriptScanVisitForTesting());
      _allMessagesById[message.id] = message;
      if (isPendingChatMessage(message)) ++_pendingMessageCount;
    }
    for (final message in messages) {
      assert(_recordTranscriptScanVisitForTesting());
      _messagesById[message.id] = message;
      final senderId = message.senderId;
      if (senderId != null) {
        (_messagesBySenderId[senderId] ??= <ChatMessage>[]).add(message);
      }
    }
    _messageIndexesDirty = false;
  }

  void _markBlockedMessagesReadThroughVisibleBoundary(List<int> blockedIds) {
    if (blockedIds.isEmpty || _allMessages.isEmpty) return;
    final visibleMax = latestServerMessageReadBoundary(
      visibleMessages: messages,
      allMessages: _allMessages,
    );
    if (visibleMax <= 0) return;
    final ids = blockedIds
        .where((id) => id <= visibleMax && !_blockedReadIds.contains(id))
        .toList();
    if (ids.isEmpty) return;
    _blockedReadIds.addAll(ids);
    for (var i = 0; i < ids.length; i += 100) {
      final end = i + 100 > ids.length ? ids.length : i + 100;
      final chunk = ids.sublist(i, end);
      // Blocked-country messages must clear locally too; only the server
      // report is skipped in ghost mode.
      if (!(allowTelegramTosViolations &&
          GhostModeController.shared.shouldBlockRead(chatId).isBlock)) {
        _client.send({
          '@type': 'viewMessages',
          'chat_id': chatId,
          'message_ids': chunk,
          'force_read': true,
        });
      }
    }
  }

  /// Re-applies what this client already knows about [incoming] messages
  /// (acknowledged sends, locally viewed mentions and reactions) before they
  /// replace their stale copies. Also tells the kept-message mirror that these
  /// messages exist: a mirror of an earlier build may have recorded TDLib's
  /// cache-unload update as a deletion, and live evidence is what repairs it.
  void _applyLocalMessageState(List<ChatMessage> incoming) {
    final accountUserId = _accountUserId;
    for (final message in incoming) {
      if (_acknowledgedPendingMessageIds.contains(message.id)) {
        message.isSendAcknowledged = true;
      }
      if (_locallyViewedMentionIds.contains(message.id)) {
        message.containsUnreadMention = false;
      }
      if (_locallyViewedReactionIds.contains(message.id)) {
        message.hasUnreadReactions = false;
      }
      if (accountUserId != null &&
          message.id > 0 &&
          !isPendingChatMessage(message)) {
        (historyStoreOverride ?? MessageHistoryStore.shared).confirmAlive(
          accountUserId,
          message.chatId ?? chatId,
          message.id,
        );
      }
    }
  }

  void _merge(List<ChatMessage> incoming) {
    if (incoming.isEmpty) return;
    _applyLocalMessageState(incoming);
    if (_appendIfStrictlyNewest(incoming)) {
      _appendToVisibleTranscript(incoming.first);
      return;
    }
    _allMessages = mergeChatMessages(
      _allMessages,
      incoming,
      ignoredMessageIds: _ignoredMergeMessageIds,
    );
    _applyKeywordFilter();
  }

  /// A live message almost always arrives newer than everything loaded, where
  /// the general merge still rebuilds a map of the whole transcript and
  /// re-sorts it. Appending skips both — but only while the list holds no
  /// pending send, because then the comparator is a plain ascending id order
  /// and the tail is provably the largest element.
  bool _appendIfStrictlyNewest(List<ChatMessage> incoming) {
    if (incoming.length != 1 || _allMessages.isEmpty) return false;
    final message = incoming.first;
    if (isPendingChatMessage(message)) return false;
    _ensureMessageIndexes();
    if (_pendingMessageCount > 0) return false;
    if (_allMessages.last.id >= message.id) return false;
    if (_allMessagesById.containsKey(message.id)) return false;
    if (_ignoredMergeMessageIds.contains(message.id)) return false;
    _allMessages.add(message);
    _messageIndexesDirty = true;
    return true;
  }

  Set<int>? _ignoredMergeMessageIdsCache;

  /// Union of the two pending-id sets. Building it inline allocated a fresh
  /// set of up to 512 ids on every merge.
  Set<int> get _ignoredMergeMessageIds => _ignoredMergeMessageIdsCache ??= {
    ..._discardedPendingMessageIds,
    ..._settledPendingMessageIds,
  };

  final Set<int> _loadingFullRichMessageIds = <int>{};

  void _replaceRichMessageContent(int messageId, Map<String, dynamic> content) {
    final refs = _messageRefs(messageId);
    if (refs.isEmpty) return;
    final full = content.obj('message')?.boolean('is_full') ?? false;
    final text = TDParse.richMessageDisplayText(content);
    final entities = TDParse.messageTextEntities(content);
    final blocks = TDParse.richMessageBlocks(content);
    final customEmoji = TDParse.customEmojiEntitiesForContent(content);
    for (final message in refs) {
      message.text = text;
      message.textEntities = entities;
      message.richBlocks = blocks;
      message.customEmoji = customEmoji;
      message.richMessageIsFull = full;
    }
    _applyKeywordFilter();
  }

  void _resolveRichMessagesIfNeeded(List<ChatMessage> candidates) {
    for (final message in candidates) {
      if (message.contentType != 'messageRichMessage' ||
          message.richMessageIsFull ||
          !_loadingFullRichMessageIds.add(message.id)) {
        continue;
      }
      unawaited(_loadFullRichMessage(message.id));
    }
  }

  Future<void> _loadFullRichMessage(int messageId) async {
    try {
      final richMessage = await _client.query({
        '@type': 'getFullRichMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      _replaceRichMessageContent(messageId, {
        '@type': 'messageRichMessage',
        'message': richMessage,
      });
    } catch (error) {
      // Keep the partial placeholder; a later content/history update retries it.
      debugPrint('Failed to load full rich message $messageId: $error');
    } finally {
      _loadingFullRichMessageIds.remove(messageId);
    }
  }

  void _setTranslationLoading(int messageId, bool loading) {
    final target = _messageRefs(messageId);
    if (target.isEmpty) return;
    for (final message in target) {
      message.isTranslating = loading;
    }
    _scheduleCoalescedNotify();
  }

  void _replaceTranslation(
    int messageId,
    String text,
    List<MessageTextEntity> entities,
    String languageCode,
  ) {
    final target = _messageRefs(messageId);
    if (target.isEmpty) return;
    for (final message in target) {
      message.translationText = text;
      message.translationEntities = entities;
      message.translationLanguageCode = languageCode;
      message.isTranslating = false;
    }
    _scheduleCoalescedNotify();
  }

  void restoreMessageTranslation(
    int messageId,
    MessageTranslationResult translation,
  ) {
    _replaceTranslation(
      messageId,
      translation.text,
      translation.entities,
      translation.languageCode,
    );
  }

  void clearTranslations(Iterable<int> messageIds) {
    var changed = false;
    for (final messageId in messageIds.toSet()) {
      for (final message in _messageRefs(messageId)) {
        if (message.translationText == null && !message.isTranslating) continue;
        message.translationText = null;
        message.translationEntities = const [];
        message.translationLanguageCode = null;
        message.isTranslating = false;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  List<ChatMessage> _messageRefs(int messageId) {
    _ensureMessageIndexes();
    final refs = <ChatMessage>[];
    final visible = _messagesById[messageId];
    final loaded = _allMessagesById[messageId];
    if (visible != null) refs.add(visible);
    if (loaded != null && (visible == null || !identical(visible, loaded))) {
      refs.add(loaded);
    }
    final buffered = _latestHistoryLiveArrivals[messageId];
    if (buffered != null &&
        !refs.any((message) => identical(message, buffered))) {
      refs.add(buffered);
    }
    return refs;
  }

  void _removeMessages(List<int> ids) {
    if (ids.isEmpty) return;
    final removed = ids.toSet();
    _allMessages.removeWhere((m) => removed.contains(m.id));
    // Reassign (never mutate in place): the transcript memo in chat_view
    // caches on the list's identity, so an in-place removeWhere would keep
    // rendering the deleted message.
    messages = messages.where((m) => !removed.contains(m.id)).toList();
    // This path bypasses _applyKeywordFilter, so the lookup indexes would
    // otherwise keep handing out deleted messages.
    _messageIndexesDirty = true;
    _blockedReadIds.removeWhere(removed.contains);
    // Same reason: the incremental append path hands this list straight to the
    // read-boundary marker, so a deleted id left here is force-read again (and
    // never dropped until the next full pass).
    _blockedMessageIds.removeWhere(removed.contains);
    if (replyTo != null && removed.contains(replyTo!.id)) replyTo = null;
    if (pinnedMessages.any((m) => removed.contains(m.id))) {
      pinnedMessages = pinnedMessages
          .where((m) => !removed.contains(m.id))
          .toList();
      pinnedMessageIndex = pinnedMessageIndex.clamp(
        0,
        math.max(0, pinnedMessages.length - 1),
      );
      pinnedMessage = pinnedMessages.isEmpty
          ? null
          : pinnedMessages[pinnedMessageIndex];
      _applyPinnedDismissal();
    }
    notifyListeners();
  }

  void _patchSender(_SenderInfo info, int senderId) {
    _patchSenders(<int, _SenderInfo>{senderId: info});
  }

  void _patchSenders(Map<int, _SenderInfo> senders) {
    if (senders.isEmpty) return;
    // Walk only the bubbles of the senders being patched. _resolveSender fires
    // this twice per sender, so a whole-transcript walk per call was the bulk
    // of the cost of opening or paging a busy group.
    _ensureMessageIndexes();
    var changed = false;
    for (final entry in senders.entries) {
      final bucket = _messagesBySenderId[entry.key];
      if (bucket == null) continue;
      final info = entry.value;
      for (final m in bucket) {
        if (m.isOutgoing && !m.senderIsChat) continue;
        if (m.senderName == info.name &&
            _sameSenderPhoto(m.senderPhoto, info.photo) &&
            m.senderRole == info.role &&
            m.senderTitle == (info.title ?? m.senderTitle) &&
            m.senderIsPremium == info.isPremium &&
            m.senderIsDeleted == info.isDeleted &&
            m.senderAccentColorId == info.accentColorId &&
            m.senderEmojiStatusId == info.emojiStatusId &&
            m.senderPresence == info.presence) {
          continue;
        }
        m.senderName = info.name;
        m.senderPhoto = info.photo;
        m.senderRole = info.role;
        m.senderTitle = info.title ?? m.senderTitle;
        m.senderIsPremium = info.isPremium;
        m.senderIsDeleted = info.isDeleted;
        m.senderAccentColorId = info.accentColorId;
        m.senderEmojiStatusId = info.emojiStatusId;
        m.senderPresence = info.presence;
        changed = true;
      }
    }
    // Ghost bubbles never join the id/sender indexes (their ids no longer
    // exist on Telegram's side), so the loop above cannot reach them. Patch
    // the folded ghosts of the resolved senders directly — otherwise a group
    // ghost stays unattributed until the next full transcript rebuild.
    if (allowTelegramTosViolations) {
      for (final m in messages) {
        final entry = m.mirrorEntry;
        if (entry == null) continue;
        final info = senders[entry.senderId];
        if (info == null) continue;
        if (m.senderName != info.name ||
            !_sameSenderPhoto(m.senderPhoto, info.photo) ||
            m.senderRole != info.role ||
            m.senderTitle != (info.title ?? m.senderTitle) ||
            m.senderIsPremium != info.isPremium ||
            m.senderIsDeleted != info.isDeleted ||
            m.senderAccentColorId != info.accentColorId ||
            m.senderEmojiStatusId != info.emojiStatusId ||
            m.senderPresence != info.presence) {
          m.senderName = info.name;
          m.senderPhoto = info.photo;
          m.senderRole = info.role;
          m.senderTitle = info.title ?? m.senderTitle;
          m.senderIsPremium = info.isPremium;
          m.senderIsDeleted = info.isDeleted;
          m.senderAccentColorId = info.accentColorId;
          m.senderEmojiStatusId = info.emojiStatusId;
          m.senderPresence = info.presence;
          changed = true;
        }
      }
    }
    if (changed) _scheduleCoalescedNotify();
  }

  bool _sameSenderPhoto(TdFileRef? current, TdFileRef? next) {
    if (identical(current, next)) return true;
    if (current == null || next == null) return false;
    return current.id == next.id &&
        current.localPath == next.localPath &&
        current.photoId == next.photoId &&
        current.hasAnimation == next.hasAnimation;
  }

  /// Folds a burst of background patches into one notify per frame. Every
  /// notify drives a full chat-screen rebuild, and the per-message resolvers
  /// (senders, replies, forwards, service text, translations) each complete on
  /// their own round trip.
  void _scheduleCoalescedNotify() {
    if (_isDisposed) return;
    if (_coalescedNotifyTimer != null) return;
    _coalescedNotifyTimer = Timer(const Duration(milliseconds: 16), () {
      _coalescedNotifyTimer = null;
      notifyListeners();
    });
  }

  // MARK: - Sender resolution (groups/channels only)

  void _resolveSendersIfNeeded(List<ChatMessage> batch) {
    if (!isGroup) return;
    final senderIds = _resolvableSenderIds(batch);
    final cachedToPatch = _primeCachedSenderIdentities(senderIds);
    final pending = <int>{};
    for (final senderId in senderIds) {
      final cached = _senderCache[senderId];
      if (cached != null) {
        cachedToPatch[senderId] = cached;
        if (!_resolvedSenderDetails.contains(senderId) &&
            !_resolvingSenders.contains(senderId)) {
          pending.add(senderId);
        }
      } else if (!_resolvingSenders.contains(senderId)) {
        pending.add(senderId);
      }
    }
    _patchSenders(cachedToPatch);
    for (final senderId in pending) {
      _resolvingSenders.add(senderId);
      _resolveSender(senderId);
    }
  }

  Set<int> _resolvableSenderIds(Iterable<ChatMessage> batch) => {
    for (final message in batch)
      if (!(message.isOutgoing && !message.senderIsChat) &&
          !message.isService &&
          message.senderId != null)
        message.senderId!,
  };

  Map<int, _SenderInfo> _primeCachedSenderIdentities(Set<int> senderIds) {
    final primed = <int, _SenderInfo>{};
    for (final senderId in senderIds) {
      if (senderId <= 0) continue;
      final user = TdUserIndex.shared.userFor(_client.activeSlot, senderId);
      if (user == null) continue;
      final existing = _senderCache[senderId];
      final info = _senderInfoFromUser(
        user,
        role: existing?.role ?? MemberRole.member,
        title: existing?.title,
      );
      _senderCache[senderId] = info;
      primed[senderId] = info;
    }
    return primed;
  }

  @visibleForTesting
  void primeCachedSenderIdentitiesForTesting() {
    _patchSenders(_primeCachedSenderIdentities(_resolvableSenderIds(messages)));
  }

  @visibleForTesting
  void applySenderUserUpdateForTesting(Map<String, dynamic> user) {
    _applySenderUserUpdate(user);
  }

  @visibleForTesting
  void applyLiveUpdateForTesting(Map<String, dynamic> update) {
    _handle(update);
  }

  /// Marks the read-state gates satisfied so read-marking paths can be
  /// exercised without replaying the whole history bootstrap.
  @visibleForTesting
  void markChatReadStateReadyForTesting() {
    _chatReadStateLoaded = true;
    _historyReachesLatest = true;
  }

  @visibleForTesting
  void isForumForTesting(bool value) {
    isForum = value;
  }

  @visibleForTesting
  void supportsBotTopicsForTesting(bool value) {
    supportsBotTopics = value;
  }

  @visibleForTesting
  void historyReachesLatestForTesting() {
    _historyReachesLatest = true;
  }

  @visibleForTesting
  void mergeMessageForTesting(ChatMessage message) {
    _merge([message]);
  }

  void _applySenderUserUpdate(Map<String, dynamic> user) {
    if (!isGroup) return;
    final userId = user.int64('id');
    if (userId == null) return;
    // TDLib emits updateUser for every user the account learns about, so test
    // the cheap cache before touching the transcript at all.
    if (!_senderCache.containsKey(userId) && !_hasVisibleSender(userId)) return;
    final existing = _senderCache[userId];
    final info = _senderInfoFromUser(
      user,
      role: existing?.role ?? MemberRole.member,
      title: existing?.title,
    );
    _senderCache[userId] = info;
    _patchSender(info, userId);
  }

  bool _hasVisibleSender(int userId) {
    _ensureMessageIndexes();
    final bucket = _messagesBySenderId[userId];
    if (bucket == null) return false;
    for (final message in bucket) {
      if (message.isOutgoing && !message.senderIsChat) continue;
      if (message.isService) continue;
      return true;
    }
    return false;
  }

  _SenderInfo _senderInfoFromUser(
    Map<String, dynamic> user, {
    required MemberRole role,
    required String? title,
  }) {
    return _SenderInfo(
      TDParse.userName(user),
      TDParse.smallPhoto(user.obj('profile_photo')),
      role,
      title,
      isPremium: user.boolean('is_premium') ?? false,
      isDeleted: TDParse.isDeletedUser(user),
      accentColorId: user.integer('accent_color_id') ?? -1,
      emojiStatusId: TDParse.emojiStatusCustomEmojiId(user.obj('emoji_status')),
      presence: TDParse.userAvatarPresence(user),
      isBot: TDParse.isBotUser(user),
    );
  }

  /// Fills `forwardOrigin` for forwarded messages whose origin is a user or
  /// chat we can name (hidden-user names already arrive inline).
  void _resolveForwardsIfNeeded(List<ChatMessage> batch) {
    _resolveViaBotsIfNeeded(batch);
    for (final m in batch) {
      if (m.forwardOrigin != null && m.forwardOrigin!.isNotEmpty) continue;
      final uid = m.forwardFromUserId;
      final cid = m.forwardFromChatId;
      if (uid != null) {
        final cached = _senderCache[uid]?.name ?? _forwardUserNames[uid];
        if (cached != null) {
          m.forwardOrigin = cached;
          continue;
        }
        final waiting = _pendingForwardUsers[uid];
        if (waiting != null) {
          waiting.add(m);
          continue;
        }
        _pendingForwardUsers[uid] = <ChatMessage>[m];
        _resolveForwardName(userId: uid);
      } else if (cid != null) {
        final cached = _forwardChatTitles[cid];
        if (cached != null) {
          m.forwardOrigin = cached;
          continue;
        }
        final waiting = _pendingForwardChats[cid];
        if (waiting != null) {
          waiting.add(m);
          continue;
        }
        _pendingForwardChats[cid] = <ChatMessage>[m];
        _resolveForwardName(chatId: cid);
      }
    }
  }

  // Forwards arrive in runs from the same origin, and the resolver used to keep
  // no result and no in-flight set: a page with 20 forwards from one channel
  // fired 20 identical getChat round trips, and every later page repeated them.
  // Chat and user ids need separate maps — TDLib chat ids for groups/channels
  // are already negative, and a private chat id equals its user id.
  final Map<int, String> _forwardUserNames = {};

  final Map<int, String> _forwardChatTitles = {};

  final Map<int, List<ChatMessage>> _pendingForwardUsers = {};

  final Map<int, List<ChatMessage>> _pendingForwardChats = {};

  final Map<int, String> _viaBotUsernames = {};

  final Map<int, List<ChatMessage>> _pendingViaBotUsers = {};

  /// Collapses any open composer panel without touching the draft or caret.
  void dismissComposerPanels() {
    if (_isDisposed) return;
    _composerDismissTick++;
    notifyListeners();
  }

  /// Set once a getForumTopics round-trip has landed (success or failure).
  /// Only then does a topic missing from [forumTopics] mean "new"; before
  /// that every topic is missing because the page is still in flight.
  /// Hands the topic a send just started to the host exactly once: the
  /// transcript switches to it after the send settles.
  int? consumePendingBotTopicOpen() {
    final topicId = _pendingBotTopicOpen;
    _pendingBotTopicOpen = null;
    return topicId;
  }
}
