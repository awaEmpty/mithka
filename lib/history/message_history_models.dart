//
//  message_history_models.dart
//
//  Data model shared by the kept-message mirror (store, viewer, per-message
//  revision sheet). Every record is owned by the account whose TDLib client
//  received it. Part of the Telegram API Terms §1.4 feature set; see
//  message_history_store.dart for the guard design.
//

import 'package:flutter/foundation.dart';

/// What the counterpart did to a mirrored message.
enum MessageHistoryState {
  /// The message still exists in the chat.
  active,

  /// The counterpart deleted the message; the copy is kept here only.
  deleted,
}

@immutable
class MessageHistoryEvent {
  const MessageHistoryEvent({
    required this.at,
    required this.oldText,
    required this.newText,
    this.editDate = 0,
    this.oldKindKey = '',
    this.oldMediaPath = '',
  });

  /// Unix seconds at which mithka observed the change.
  final int at;

  /// Text before the change, or null when unknown (e.g. the mirror was
  /// populated by an older build).
  final String? oldText;

  /// Text after the change.
  final String newText;

  /// TDLib's edit_date for the edit that caused the event, 0 if unknown.
  final int editDate;

  /// Content kind and media snapshot of the PREVIOUS revision, captured
  /// when the edit landed. Older mirror files lack them; they render as
  /// text-only revisions.
  final String oldKindKey;
  final String oldMediaPath;

  Map<String, Object?> toJson() => {
    'at': at,
    'old': oldText,
    'new': newText,
    'editDate': editDate,
    if (oldKindKey.isNotEmpty) 'oldKind': oldKindKey,
    if (oldMediaPath.isNotEmpty) 'oldMedia': oldMediaPath,
  };

  static MessageHistoryEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final newText = json['new'];
    if (at is! int || newText is! String) return null;
    final oldText = json['old'];
    final editDate = json['editDate'];
    final oldKindKey = json['oldKind'];
    final oldMediaPath = json['oldMedia'];
    return MessageHistoryEvent(
      at: at,
      oldText: oldText is String ? oldText : null,
      newText: newText,
      editDate: editDate is int ? editDate : 0,
      oldKindKey: oldKindKey is String ? oldKindKey : '',
      oldMediaPath: oldMediaPath is String ? oldMediaPath : '',
    );
  }

  MessageHistoryEvent copyWithOldMedia({
    String? oldKindKey,
    String? oldMediaPath,
  }) => MessageHistoryEvent(
    at: at,
    oldText: oldText,
    newText: newText,
    editDate: editDate,
    oldKindKey: oldKindKey ?? this.oldKindKey,
    oldMediaPath: oldMediaPath ?? this.oldMediaPath,
  );

  @override
  bool operator ==(Object other) =>
      other is MessageHistoryEvent &&
      other.at == at &&
      other.oldText == oldText &&
      other.newText == newText &&
      other.editDate == editDate &&
      other.oldKindKey == oldKindKey &&
      other.oldMediaPath == oldMediaPath;

  @override
  int get hashCode =>
      Object.hash(at, oldText, newText, editDate, oldKindKey, oldMediaPath);
}

/// One kept copy of one message, together with its edit trail and the media
/// snapshot path (when the media was already fully on disk when the message
/// was observed).
@immutable
class MessageHistoryEntry {
  const MessageHistoryEntry({
    required this.accountUserId,
    required this.chatId,
    required this.messageId,
    required this.senderId,
    required this.date,
    required this.text,
    required this.kindKey,
    required this.state,
    required this.deletedAt,
    required this.events,
    this.mediaPath = '',
    this.mediaWidth = 0,
    this.mediaHeight = 0,
    this.mediaDuration = 0,
    this.mediaFileName = '',
    this.mediaMimeType = '',
    this.mediaFileId = 0,
    this.mediaSourcePath = '',
    this.mediaPosterPath = '',
    this.hasLiveChat = true,
    this.topicId = 0,
  });

  /// User id of the account that received the message. Two accounts that see
  /// the same chat/message ids keep two separate records.
  final int accountUserId;

  final int chatId;
  final int messageId;

  /// A user id (positive) or, when the chat itself posted, that chat's id
  /// (negative). Display names are resolved on view, never stored.
  final int senderId;

  /// Unix seconds the message was originally sent.
  final int date;

  /// Latest known text, or the caption for media messages. Empty for media
  /// without a caption — [kindKey] then names the content.
  final String text;

  /// Content kind suffix (e.g. `historyKindPhoto`); empty for plain text.
  final String kindKey;

  final MessageHistoryState state;

  /// Unix seconds at which the deletion was observed, 0 while active.
  final int deletedAt;

  /// Content changes in observation order (oldest first).
  final List<MessageHistoryEvent> events;

  /// Path of the mirrored media file inside the mirror's attachment
  /// directory, empty when no snapshot exists.
  final String mediaPath;

  /// Pixel size of the file behind [mediaPath] (0 when unknown). The viewer
  /// and the in-chat ghost bubble size the preview from it, so a tall photo
  /// does not paint as a square and a snapshot upgrade keeps the aspect.
  final int mediaWidth;
  final int mediaHeight;

  /// Playback length of the snapped media in seconds, 0 for still content.
  final int mediaDuration;

  /// Display name and MIME type of the snapped media (documents, audio,
  /// video); empty when the content carries none.
  final String mediaFileName;
  final String mediaMimeType;

  /// TDLib file id the snapshot was (or will be) taken from. It is also the
  /// handle used to catch a download that completes after the message was
  /// recorded — a kept copy has no message on Telegram's side any more, so
  /// this is the only way back to the file.
  final int mediaFileId;

  /// TDLib's local path for [mediaFileId] at record time. A restart has no
  /// file id → path mapping; this lets the loader re-check a file that had
  /// already finished downloading.
  final String mediaSourcePath;

  /// Snapshot of the media's own thumbnail (video cover, sticker preview).
  /// The file behind [mediaPath] is the playable/original one — a player
  /// cannot paint it as a still — so this is what the bubble previews.
  final String mediaPosterPath;

  /// False once TDLib reported the chat gone (deleted account/chat): the
  /// kept copy renders in the ghost style because there is no chat to open.
  final bool hasLiveChat;

  /// Forum topic the message was posted in, 0 for ordinary chats and
  /// General's unattributed arrivals. Topic-scoped transcripts filter
  /// ghosts by it; it never identifies anything on Telegram's side once
  /// the message is gone.
  final int topicId;

  bool get isEdited => events.isNotEmpty;

  /// Whether this copy is history the viewer should list: the message was
  /// deleted or it carries an edit trail. A plain active copy exists only as
  /// the base a future deletion or edit needs, so the viewer stays a history
  /// view instead of a second inbox.
  bool get hasHistory =>
      state == MessageHistoryState.deleted || events.isNotEmpty;

  String get key => '$accountUserId:$chatId:$messageId';

  /// Localized kind label key; [AppStringKeys.historyKindUnknown] when the
  /// kind cannot be named.
  String kindLabel() => kindKey.isEmpty ? '' : kindKey;

  @override
  bool operator ==(Object other) =>
      other is MessageHistoryEntry &&
      other.accountUserId == accountUserId &&
      other.chatId == chatId &&
      other.messageId == messageId &&
      other.senderId == senderId &&
      other.date == date &&
      other.text == text &&
      other.kindKey == kindKey &&
      other.state == state &&
      other.deletedAt == deletedAt &&
      other.mediaPath == mediaPath &&
      other.hasLiveChat == hasLiveChat &&
      other.topicId == topicId &&
      listEquals(other.events, events) &&
      other.mediaWidth == mediaWidth &&
      other.mediaHeight == mediaHeight &&
      other.mediaDuration == mediaDuration &&
      other.mediaFileName == mediaFileName &&
      other.mediaMimeType == mediaMimeType &&
      other.mediaFileId == mediaFileId &&
      other.mediaSourcePath == mediaSourcePath &&
      other.mediaPosterPath == mediaPosterPath;

  @override
  int get hashCode => Object.hash(
    accountUserId,
    chatId,
    messageId,
    senderId,
    date,
    text,
    kindKey,
    state,
    deletedAt,
    mediaPath,
    hasLiveChat,
    topicId,
    Object.hashAll(events),
    mediaWidth,
    mediaHeight,
    mediaDuration,
    mediaFileName,
    mediaMimeType,
    mediaFileId,
    mediaSourcePath,
  );

  MessageHistoryEntry copyWith({
    int? accountUserId,
    String? text,
    String? kindKey,
    int? senderId,
    MessageHistoryState? state,
    int? deletedAt,
    List<MessageHistoryEvent>? events,
    String? mediaPath,
    int? mediaWidth,
    int? mediaHeight,
    int? mediaDuration,
    String? mediaFileName,
    String? mediaMimeType,
    int? mediaFileId,
    String? mediaSourcePath,
    String? mediaPosterPath,
    bool? hasLiveChat,
    int? topicId,
  }) => MessageHistoryEntry(
    accountUserId: accountUserId ?? this.accountUserId,
    chatId: chatId,
    messageId: messageId,
    senderId: senderId ?? this.senderId,
    date: date,
    text: text ?? this.text,
    kindKey: kindKey ?? this.kindKey,
    state: state ?? this.state,
    deletedAt: deletedAt ?? this.deletedAt,
    events: events ?? this.events,
    mediaPath: mediaPath ?? this.mediaPath,
    mediaWidth: mediaWidth ?? this.mediaWidth,
    mediaHeight: mediaHeight ?? this.mediaHeight,
    mediaDuration: mediaDuration ?? this.mediaDuration,
    mediaFileName: mediaFileName ?? this.mediaFileName,
    mediaMimeType: mediaMimeType ?? this.mediaMimeType,
    mediaFileId: mediaFileId ?? this.mediaFileId,
    mediaSourcePath: mediaSourcePath ?? this.mediaSourcePath,
    mediaPosterPath: mediaPosterPath ?? this.mediaPosterPath,
    hasLiveChat: hasLiveChat ?? this.hasLiveChat,
    topicId: topicId ?? this.topicId,
  );

  Map<String, Object?> toJson() => {
    'account': accountUserId,
    'chat': chatId,
    'id': messageId,
    'sender': senderId,
    'date': date,
    'text': text,
    'kind': kindKey,
    'state': state.name,
    'deletedAt': deletedAt,
    'events': [for (final event in events) event.toJson()],
    if (mediaPath.isNotEmpty) 'media': mediaPath,
    if (mediaWidth > 0) 'mediaW': mediaWidth,
    if (mediaHeight > 0) 'mediaH': mediaHeight,
    if (mediaDuration > 0) 'mediaDur': mediaDuration,
    if (mediaFileName.isNotEmpty) 'mediaName': mediaFileName,
    if (mediaMimeType.isNotEmpty) 'mediaMime': mediaMimeType,
    if (mediaFileId > 0) 'mediaFile': mediaFileId,
    if (mediaSourcePath.isNotEmpty) 'mediaSrc': mediaSourcePath,
    if (mediaPosterPath.isNotEmpty) 'mediaPoster': mediaPosterPath,
    if (!hasLiveChat) 'noChat': true,
    if (topicId > 0) 'topic': topicId,
  };

  /// Entries without an 'account' field (mirror files from before the
  /// account identity existed) are dropped on load: an entry whose owning
  /// account is unknown must never be attributed to whichever account
  /// happens to be active.
  static MessageHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final account = json['account'];
    final chat = json['chat'];
    final id = json['id'];
    final date = json['date'];
    final text = json['text'];
    if (account is! int ||
        chat is! int ||
        id is! int ||
        date is! int ||
        text is! String) {
      return null;
    }
    final sender = json['sender'];
    final kind = json['kind'];
    final state = json['state'];
    final deletedAt = json['deletedAt'];
    final events = json['events'];
    final media = json['media'];
    final mediaW = json['mediaW'];
    final mediaH = json['mediaH'];
    final mediaDur = json['mediaDur'];
    final mediaName = json['mediaName'];
    final mediaMime = json['mediaMime'];
    final mediaFile = json['mediaFile'];
    final mediaSrc = json['mediaSrc'];
    final mediaPoster = json['mediaPoster'];
    final noChat = json['noChat'];
    final topic = json['topic'];
    return MessageHistoryEntry(
      accountUserId: account,
      chatId: chat,
      messageId: id,
      senderId: sender is int ? sender : 0,
      date: date,
      text: text,
      kindKey: kind is String ? kind : '',
      state: state == 'deleted'
          ? MessageHistoryState.deleted
          : MessageHistoryState.active,
      deletedAt: deletedAt is int ? deletedAt : 0,
      events: events is List
          ? events
                .map(MessageHistoryEvent.fromJson)
                .whereType<MessageHistoryEvent>()
                .toList()
          : const [],
      mediaPath: media is String ? media : '',
      mediaWidth: mediaW is int ? mediaW : 0,
      mediaHeight: mediaH is int ? mediaH : 0,
      mediaDuration: mediaDur is int ? mediaDur : 0,
      mediaFileName: mediaName is String ? mediaName : '',
      mediaMimeType: mediaMime is String ? mediaMime : '',
      mediaFileId: mediaFile is int ? mediaFile : 0,
      mediaSourcePath: mediaSrc is String ? mediaSrc : '',
      mediaPosterPath: mediaPoster is String ? mediaPoster : '',
      hasLiveChat: noChat is bool ? !noChat : true,
      topicId: topic is int ? topic : 0,
    );
  }
}
