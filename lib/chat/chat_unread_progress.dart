import 'package:flutter/widgets.dart';

enum ChatBottomIndicator { none, newMessages, jumpToBottom }

enum ChatNewMessagesControlPlacement { hidden, top, bottom }

const unreadChatSummaryMinimumUnreadMessages = 100;

bool shouldShowUnreadChatSummaryAttachment({
  required int unreadMessageCount,
  required bool providerAvailable,
}) =>
    providerAvailable &&
    unreadMessageCount >= unreadChatSummaryMinimumUnreadMessages;

/// Keeps the unread-message badge mounted while the optional AI attachment is
/// enabled or disabled. A stable badge subtree avoids coupling the core unread
/// affordance to AI configuration changes.
class ChatNewMessagesControlShell extends StatelessWidget {
  const ChatNewMessagesControlShell({
    super.key,
    required this.unreadBadge,
    this.aiAttachment,
    this.minimumAttachmentHeight = 40,
  });

  static const unreadBadgeKey = ValueKey('chatUnreadMessagesBadge');
  static const aiAttachmentKey = ValueKey('chatUnreadMessagesAiAttachment');

  final Widget unreadBadge;
  final Widget? aiAttachment;
  final double minimumAttachmentHeight;

  @override
  Widget build(BuildContext context) {
    final attachment = aiAttachment;
    final badge = KeyedSubtree(key: unreadBadgeKey, child: unreadBadge);
    if (attachment == null) return badge;

    return Stack(
      alignment: Alignment.centerRight,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: minimumAttachmentHeight),
          child: Align(widthFactor: 1, heightFactor: 1, child: badge),
        ),
        Positioned(
          right: 0,
          child: KeyedSubtree(key: aiAttachmentKey, child: attachment),
        ),
      ],
    );
  }
}

ChatBottomIndicator chatBottomIndicator({
  required bool isScrolledUp,
  required bool hasNewMessages,
}) {
  if (!isScrolledUp) return ChatBottomIndicator.none;
  return hasNewMessages
      ? ChatBottomIndicator.newMessages
      : ChatBottomIndicator.jumpToBottom;
}

ChatNewMessagesControlPlacement chatNewMessagesControlPlacement({
  required bool isScrolledUp,
  required bool hasNewMessages,
  required bool isEntryUnread,
}) {
  if (!hasNewMessages) return ChatNewMessagesControlPlacement.hidden;
  if (isScrolledUp) return ChatNewMessagesControlPlacement.bottom;
  return isEntryUnread
      ? ChatNewMessagesControlPlacement.top
      : ChatNewMessagesControlPlacement.hidden;
}

/// Buffers only message IDs received through TDLib's `updateNewMessage` path.
/// History pages loaded while restoring a saved scroll position must never be
/// mistaken for live arrivals.
class ChatLiveMessageBuffer {
  final Set<int> _messageIds = <int>{};

  bool add(int messageId) => _messageIds.add(messageId);

  List<int> takeAll() {
    if (_messageIds.isEmpty) return const <int>[];
    final result = _messageIds.toList(growable: false);
    _messageIds.clear();
    return result;
  }
}

/// Live incoming IDs that were appended to the currently loaded transcript.
///
/// A null previous newest ID means the chat previously had no server message;
/// the first live arrival must still be surfaced if auto-follow is suppressed.
List<int> appendedLiveIncomingMessageIds({
  required int? previousNewestMessageId,
  required Iterable<int> liveIncomingMessageIds,
  required Iterable<int> currentMessageIds,
}) {
  final currentIds = currentMessageIds.toSet();
  return liveIncomingMessageIds
      .where(
        (id) =>
            (previousNewestMessageId == null || id > previousNewestMessageId) &&
            currentIds.contains(id),
      )
      .toList(growable: false);
}

/// Live outgoing IDs that were appended to the currently loaded transcript.
///
/// An own send first lands as a local echo carrying TDLib's temporary id,
/// which comes from a separate counter and can sit far BELOW the newest server
/// id — ordering cannot tell it apart from an old message, so presence in the
/// loaded window is the whole test. A message sent from another device is the
/// same event with a server id, and takes the same path.
List<int> appendedLiveOutgoingMessageIds({
  required Iterable<int> liveOutgoingMessageIds,
  required Iterable<int> currentMessageIds,
}) {
  final currentIds = currentMessageIds.toSet();
  return liveOutgoingMessageIds
      .where(currentIds.contains)
      .toList(growable: false);
}

/// Returns the earliest loaded incoming message beyond a captured read
/// boundary. The boundary must be the value from when the chat opened: TDLib
/// advances its live boundary as soon as the latest messages are marked read.
int? firstUnreadMessageIdAfterBoundary({
  required Iterable<int> incomingMessageIds,
  required int lastReadInboxId,
}) {
  int? earliest;
  for (final messageId in incomingMessageIds) {
    if (messageId <= lastReadInboxId) continue;
    if (earliest == null || messageId < earliest) earliest = messageId;
  }
  return earliest;
}

/// Whether [messageId] belonged to the unread range captured when the chat
/// entry state was recorded. The upper bound prevents later auto-followed
/// arrivals from consuming the fixed entry unread count after their live-ID
/// marker has already been cleared.
bool isCapturedEntryUnreadMessage({
  required int messageId,
  required int lastReadInboxId,
  required int latestMessageId,
}) => messageId > lastReadInboxId && messageId <= latestMessageId;

/// Whether a transcript row begins the unread range captured when the chat
/// opened. Live TDLib read updates must not be used here: viewing the row can
/// advance the live boundary while the divider is still on screen.
bool isCapturedUnreadDividerMessage({
  required int entryUnreadCount,
  required int? firstUnreadMessageId,
  required int messageId,
  required bool isIncoming,
  required bool isService,
  required int lastReadInboxId,
  required int latestMessageId,
}) {
  if (entryUnreadCount <= 0 ||
      firstUnreadMessageId == null ||
      messageId != firstUnreadMessageId ||
      !isIncoming ||
      isService) {
    return false;
  }
  if (!isCapturedEntryUnreadMessage(
    messageId: messageId,
    lastReadInboxId: lastReadInboxId,
    latestMessageId: latestMessageId,
  )) {
    return false;
  }
  return true;
}

int resolveCapturedEntryLatestMessageId({
  required int knownLatestMessageId,
  required int loadedLatestMessageId,
}) => knownLatestMessageId > 0 ? knownLatestMessageId : loadedLatestMessageId;

class ChatUnreadProgress {
  final Set<int> _seenInitialMessageIds = <int>{};
  final Set<int> _liveMessageIds = <int>{};
  final Set<int> _reportedVisibleMessageIds = <int>{};

  int get liveCount => _liveMessageIds.length;

  int initialRemaining({required int entryUnreadCount}) =>
      (entryUnreadCount - _seenInitialMessageIds.length).clamp(0, 1 << 30);

  int remaining({required int entryUnreadCount}) =>
      initialRemaining(entryUnreadCount: entryUnreadCount) + liveCount;

  /// Count shown by the new-message control. Live arrivals retain their
  /// existing priority, while entry unread messages now reflect what has
  /// actually entered the viewport instead of staying frozen at open time.
  int badgeCount({required int entryUnreadCount}) => liveCount > 0
      ? liveCount
      : initialRemaining(entryUnreadCount: entryUnreadCount);

  bool addLiveMessage(int messageId) => _liveMessageIds.add(messageId);

  bool addLiveMessages(Iterable<int> messageIds) {
    var changed = false;
    for (final messageId in messageIds) {
      changed = _liveMessageIds.add(messageId) || changed;
    }
    return changed;
  }

  bool markVisible({required int messageId, required bool initialUnread}) {
    if (_liveMessageIds.remove(messageId)) return true;
    return initialUnread && _seenInitialMessageIds.add(messageId);
  }

  /// Channel posts already reported to TDLib while they stayed on screen.
  final Set<int> _reportedChannelPostIds = <int>{};

  /// Records one channel post intersecting the laid-out viewport.
  ///
  /// True only while the post stays on screen. TDLib refreshes a channel
  /// post's counters solely from a `messages.getMessagesViews` answer, and it
  /// asks for one exactly when `viewMessages` names the post — so a post that
  /// left the viewport must be reportable again, or its counts would stay at
  /// whatever the page that first loaded it carried.
  bool markChannelPostReported({required int messageId}) =>
      _reportedChannelPostIds.add(messageId);

  /// Forgets the reports of posts that are no longer on screen, so scrolling
  /// back to one reports it again.
  void retainVisibleChannelPosts(Set<int> visibleMessageIds) =>
      _reportedChannelPostIds.retainAll(visibleMessageIds);

  /// Records one incoming message intersecting the laid-out viewport.
  ///
  /// [shouldReportViewed] is true only on the first observation so callers can
  /// issue TDLib's `viewMessages` exactly once even when layout is measured
  /// again without a scroll event.
  ({bool shouldReportViewed, bool unreadCountChanged}) observeVisibleIncoming({
    required int messageId,
    required bool initialUnread,
  }) => (
    shouldReportViewed: _reportedVisibleMessageIds.add(messageId),
    unreadCountChanged: markVisible(
      messageId: messageId,
      initialUnread: initialUnread,
    ),
  );

  bool clearLiveMessages() {
    if (_liveMessageIds.isEmpty) return false;
    _liveMessageIds.clear();
    return true;
  }
}
