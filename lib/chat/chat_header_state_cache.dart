part of 'chat_view_model.dart';

/// Chat header facts that do not depend on which forum topic is open:
/// peer presence, bot identity and menus, member counts, group status.
///
/// A topic switch rebuilds the whole transcript (ChatView reads its topic
/// once), and the fresh view model starts these fields at their empty
/// defaults — the header paints one line short and the pinned topic strip
/// jumps a beat later when getUser/getSupergroup resolve. Carrying the last
/// known values across topic swaps keeps the header's height steady on the
/// first frame; the normal async loads then refresh them in place.
class ChatHeaderStateCache {
  ChatHeaderStateCache._();

  static final Map<({int accountSlot, int chatId}), ChatHeaderSnapshot>
  _byChat = {};

  static ChatHeaderSnapshot? read(int accountSlot, int chatId) =>
      _byChat[(accountSlot: accountSlot, chatId: chatId)];

  static void write(ChatHeaderSnapshot snapshot) {
    _byChat[(accountSlot: snapshot.accountSlot, chatId: snapshot.chatId)] =
        snapshot;
  }

  /// Drops every snapshot. Tests only.
  static void resetForTesting() => _byChat.clear();

  /// Merges translation-language detection state into an existing snapshot.
  /// The language detection lives in [ChatView] (UI state), not the view
  /// model, so it is written separately after the VM snapshot lands.
  static void updateLanguageState({
    required int accountSlot,
    required int chatId,
    required String? detectedChatLanguage,
    required bool complete,
    required DateTime? detectedAt,
    required int? newestMessageId,
    required bool translatable,
    required String translationSettingsKey,
  }) {
    final key = (accountSlot: accountSlot, chatId: chatId);
    final existing =
        _byChat[key] ??
        ChatHeaderSnapshot(
          accountSlot: accountSlot,
          chatId: chatId,
          isForum: false,
          hasForumTabs: false,
          supportsBotTopics: false,
          botTopicsManageable: false,
          isGroup: false,
          isChannel: false,
          isBotApiAccount: false,
          memberCount: 0,
          peerOnline: false,
          peerStatusText: '',
          peerIsBot: false,
          botMenu: null,
          botCommands: const [],
          botApiCanReadAllGroupMessages: false,
          botApiBotToBotAccessObserved: false,
          detectedChatLanguage: null,
          chatLanguageDetectionComplete: false,
          chatLanguageDetectedAt: null,
          chatLanguageDetectionNewestMessageId: null,
          chatTranslatable: false,
          translationSettingsKey: '',
        );
    _byChat[key] = existing.copyWith(
      detectedChatLanguage: detectedChatLanguage,
      chatLanguageDetectionComplete: complete,
      chatLanguageDetectedAt: detectedAt,
      chatLanguageDetectionNewestMessageId: newestMessageId,
      chatTranslatable: translatable,
      translationSettingsKey: translationSettingsKey,
    );
  }
}

/// The header-derived fields a topic swap must inherit. Peer identity fields
/// (title, photo) come through the chat object itself and stay out; only the
/// late-arriving, height-affecting facts live here.
class ChatHeaderSnapshot {
  ChatHeaderSnapshot({
    required this.accountSlot,
    required this.chatId,
    required this.isForum,
    required this.hasForumTabs,
    required this.supportsBotTopics,
    required this.botTopicsManageable,
    required this.isGroup,
    required this.isChannel,
    required this.isBotApiAccount,
    required this.memberCount,
    required this.peerOnline,
    required this.peerStatusText,
    required this.peerIsBot,
    required this.botMenu,
    required this.botCommands,
    required this.botApiCanReadAllGroupMessages,
    required this.botApiBotToBotAccessObserved,
    required this.detectedChatLanguage,
    required this.chatLanguageDetectionComplete,
    required this.chatLanguageDetectedAt,
    required this.chatLanguageDetectionNewestMessageId,
    required this.chatTranslatable,
    required this.translationSettingsKey,
  });

  final int accountSlot;
  final int chatId;

  /// Whether the chat is a forum (`view_as_topics` / supergroup forum).
  final bool isForum;

  /// The supergroup's server-side tab flag: a forum with tabs paints the
  /// horizontal strip, one without keeps the rail.
  final bool hasForumTabs;

  /// A private chat whose bot advertises `has_topics` — the only surface that
  /// exposes the tab-position control and the side dock.
  final bool supportsBotTopics;

  /// The bot's own topic-management flag (`allows_users_to_create_topics`).
  final bool botTopicsManageable;

  final bool isGroup;
  final bool isChannel;
  final bool isBotApiAccount;
  final int memberCount;
  final bool peerOnline;
  final String peerStatusText;
  final bool peerIsBot;
  final BotMenuInfo? botMenu;
  final List<BotCommandOption> botCommands;
  final bool botApiCanReadAllGroupMessages;
  final bool botApiBotToBotAccessObserved;
  final String? detectedChatLanguage;
  final bool chatLanguageDetectionComplete;
  final DateTime? chatLanguageDetectedAt;
  final int? chatLanguageDetectionNewestMessageId;

  /// Whether the chat's messages are in a language the user translates.
  /// Produced by the chat translatability classifier; see
  /// `decideChatTranslation`.
  final bool chatTranslatable;

  /// Target language plus the "do not translate" list when
  /// [chatTranslatable] was computed. A different key means the verdict is
  /// stale (the classifier's `shouldTranslate` input changed) and must be
  /// recomputed even when the sample set did not move.
  final String translationSettingsKey;

  ChatHeaderSnapshot copyWith({
    String? detectedChatLanguage,
    bool? chatLanguageDetectionComplete,
    DateTime? chatLanguageDetectedAt,
    int? chatLanguageDetectionNewestMessageId,
    bool? chatTranslatable,
    String? translationSettingsKey,
  }) {
    return ChatHeaderSnapshot(
      accountSlot: accountSlot,
      chatId: chatId,
      isForum: isForum,
      hasForumTabs: hasForumTabs,
      supportsBotTopics: supportsBotTopics,
      botTopicsManageable: botTopicsManageable,
      isGroup: isGroup,
      isChannel: isChannel,
      isBotApiAccount: isBotApiAccount,
      memberCount: memberCount,
      peerOnline: peerOnline,
      peerStatusText: peerStatusText,
      peerIsBot: peerIsBot,
      botMenu: botMenu,
      botCommands: botCommands,
      botApiCanReadAllGroupMessages: botApiCanReadAllGroupMessages,
      botApiBotToBotAccessObserved: botApiBotToBotAccessObserved,
      detectedChatLanguage: detectedChatLanguage ?? this.detectedChatLanguage,
      chatLanguageDetectionComplete:
          chatLanguageDetectionComplete ?? this.chatLanguageDetectionComplete,
      chatLanguageDetectedAt:
          chatLanguageDetectedAt ?? this.chatLanguageDetectedAt,
      chatLanguageDetectionNewestMessageId:
          chatLanguageDetectionNewestMessageId ??
          this.chatLanguageDetectionNewestMessageId,
      chatTranslatable: chatTranslatable ?? this.chatTranslatable,
      translationSettingsKey:
          translationSettingsKey ?? this.translationSettingsKey,
    );
  }
}
