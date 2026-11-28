import 'package:flutter/material.dart';
import '../app/adaptive_split_layout.dart';
import '../chat/stickers/custom_emoji.dart';
import '../components/app_icons.dart';
import '../components/chat_folder_icons.dart';
import '../components/full_page_back_swipe.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';
import 'topic_list_row.dart';
import 'topic_tabs_placement.dart';

class TopicNavigationItem {
  const TopicNavigationItem({
    required this.id,
    required this.name,
    this.iconCustomEmojiId = 0,
    this.iconColor = 0,
    this.unreadCount = 0,
    this.isMuted = false,
    this.isPinned = false,
    this.isGeneral = false,
    this.isClosed = false,
    this.lastPreview = '',
    this.lastSender,
    this.lastMessageDate = 0,
  });

  final int id;
  final String name;
  final int iconCustomEmojiId;
  final int iconColor;

  /// Live unread messages in this topic, maintained through the shared forum
  /// topic index; 0 when unknown.
  final int unreadCount;
  final bool isMuted;
  final bool isPinned;

  /// The General topic (id 1): shows the chat avatar and cannot be deleted.
  final bool isGeneral;
  final bool isClosed;

  /// Last-message preview text with media/service placeholders already
  /// composed the way the chat list composes them; empty hides the line.
  final String lastPreview;

  /// Sender prefix for [lastPreview] ("Alice", "You:"), null for none.
  final String? lastSender;

  /// Unix seconds of the last message; 0 hides the timestamp.
  final int lastMessageDate;

  /// Whether any chat-list-style row data is present, so a compact rail that
  /// lacks it can keep its 44px chip rows instead of half-empty list rows.
  bool get hasRowDetail =>
      lastPreview.isNotEmpty || lastMessageDate > 0 || isPinned;

  /// Display-field equality, so a republished list that changed nothing
  /// never re-notifies a listening shell.
  bool sameDisplay(TopicNavigationItem other) =>
      id == other.id &&
      name == other.name &&
      iconCustomEmojiId == other.iconCustomEmojiId &&
      iconColor == other.iconColor &&
      unreadCount == other.unreadCount &&
      isMuted == other.isMuted &&
      isPinned == other.isPinned &&
      isGeneral == other.isGeneral &&
      isClosed == other.isClosed &&
      lastPreview == other.lastPreview &&
      lastSender == other.lastSender &&
      lastMessageDate == other.lastMessageDate;
}

/// One action offered by a topic row's context menu.
class TopicRowAction {
  const TopicRowAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  /// Stable identifier, also used as the menu row's ValueKey suffix.
  final String key;
  final String label;
  final AppIconData icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// A topic row's context menu request: the topic and where the gesture
/// landed (desktop right-click anchors a positioned menu there).
typedef TopicRowMenuRequest =
    void Function(TopicNavigationItem topic, Offset? globalPosition);

/// The group's has_forum_tabs setting selects top tabs; other wide topic
/// chats show a rail at the left edge of their conversation pane.
class TopicNavigationLayout extends StatelessWidget {
  const TopicNavigationLayout({
    super.key,
    required this.topics,
    required this.selectedTopicId,
    required this.hasForumTabs,
    required this.onSelected,
    required this.child,
    this.onCreateTopic,
    this.onMarkAllRead,
    this.onTopicMenu,
    this.generalAvatarTitle = '',
    this.generalAvatarPhoto,
    this.placement = TopicTabsPlacement.top,
    this.onTogglePlacement,
    this.bottomBar,
  });

  final List<TopicNavigationItem> topics;
  final int? selectedTopicId;
  final bool hasForumTabs;
  final ValueChanged<int?> onSelected;
  final Widget child;

  /// Telegram iOS offers topic creation from the topic list itself; null
  /// hides the affordance (no can_create_topics / can_manage_topics right).
  final VoidCallback? onCreateTopic;

  /// Clears every unread topic at once; null while no topic is unread.
  final VoidCallback? onMarkAllRead;
  final TopicRowMenuRequest? onTopicMenu;
  final String generalAvatarTitle;
  final TdFileRef? generalAvatarPhoto;

  /// Where the horizontal topic tab bar sits: above the topic content, or
  /// between it and [bottomBar] (the composer), the way exteraless's per-chat
  /// tabs position works. The vertical rail ignores it.
  final TopicTabsPlacement placement;

  /// Moves the tab bar to the other side. Null hides the control (wide
  /// layouts keep their rail/top tabs fixed).
  final VoidCallback? onTogglePlacement;

  /// Kept below the tab bar in both placements — the topic screen's composer.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    // A side placement borrows the rail: the reference client's side tabs are
    // the same vertical column the wide shell already uses for a forum
    // without server tabs.
    final vertical =
        placement == TopicTabsPlacement.side ||
        (usesSplitSelectionLayout(MediaQuery.sizeOf(context)) && !hasForumTabs);
    final detailed = topics.any((topic) => topic.hasRowDetail);
    final navigation = _TopicNavigation(
      topics: topics,
      selectedTopicId: selectedTopicId,
      vertical: vertical,
      detailed: vertical && detailed,
      onSelected: onSelected,
      onCreateTopic: vertical ? onCreateTopic : null,
      onMarkAllRead: onMarkAllRead,
      onTopicMenu: onTopicMenu,
      generalAvatarTitle: generalAvatarTitle,
      generalAvatarPhoto: generalAvatarPhoto,
      placement: placement,
      onTogglePlacement: vertical ? null : onTogglePlacement,
    );
    if (!vertical) {
      final tabs = SizedBox(height: 44, child: navigation);
      return Column(
        children: [
          if (placement == TopicTabsPlacement.top) tabs,
          Expanded(child: child),
          if (placement == TopicTabsPlacement.bottom) tabs,
          ?bottomBar,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          SizedBox(
            width: detailed
                ? (constraints.maxWidth * 0.30).clamp(212.0, 280.0)
                : (constraints.maxWidth * 0.24).clamp(120.0, 196.0),
            child: navigation,
          ),
          Expanded(
            child: Column(
              children: [
                Expanded(child: child),
                ?bottomBar,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopicNavigation extends StatelessWidget {
  const _TopicNavigation({
    required this.topics,
    required this.selectedTopicId,
    required this.vertical,
    required this.detailed,
    required this.onSelected,
    this.onCreateTopic,
    this.onMarkAllRead,
    this.onTopicMenu,
    this.generalAvatarTitle = '',
    this.generalAvatarPhoto,
    this.placement = TopicTabsPlacement.top,
    this.onTogglePlacement,
  });

  final List<TopicNavigationItem> topics;
  final int? selectedTopicId;
  final bool vertical;

  /// Vertical rails with preview data draw chat-list-style rows.
  final bool detailed;
  final ValueChanged<int?> onSelected;
  final VoidCallback? onCreateTopic;
  final VoidCallback? onMarkAllRead;
  final TopicRowMenuRequest? onTopicMenu;
  final String generalAvatarTitle;
  final TdFileRef? generalAvatarPhoto;
  final TopicTabsPlacement placement;
  final VoidCallback? onTogglePlacement;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final list = detailed ? _detailedList(context) : _compactList(context);
    return Container(
      key: ValueKey(
        vertical ? 'topic-navigation-left' : 'topic-navigation-top',
      ),
      decoration: BoxDecoration(
        color: c.background,
        border: vertical
            ? Border(right: BorderSide(color: c.divider, width: 0.5))
            : Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      // A wide rail keeps its header; the horizontal bar puts the tabs
      // position control at the leading edge, like the chat transcript's.
      child: vertical
          ? Column(
              children: [
                if (detailed &&
                    (onCreateTopic != null || onMarkAllRead != null))
                  _RailHeader(
                    onCreateTopic: onCreateTopic,
                    onMarkAllRead: onMarkAllRead,
                  ),
                Expanded(child: list),
              ],
            )
          : Row(
              children: [
                if (onTogglePlacement != null)
                  _TopicTabsPlacementToggle(
                    placement: placement,
                    onTap: onTogglePlacement!,
                  ),
                Expanded(child: list),
              ],
            ),
    );
  }

  Widget _detailedList(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 6),
    itemCount: topics.length + 1,
    itemBuilder: (context, index) {
      final topic = index == 0 ? null : topics[index - 1];
      return TopicListRowView(
        topic: topic,
        selected: topic?.id == selectedTopicId,
        onTap: () => onSelected(topic?.id),
        onLongPress: topic == null || onTopicMenu == null
            ? null
            : () => onTopicMenu!(topic, null),
        onSecondaryTapDown: topic == null || onTopicMenu == null
            ? null
            : (details) => onTopicMenu!(topic, details.globalPosition),
        generalAvatarTitle: generalAvatarTitle,
        generalAvatarPhoto: generalAvatarPhoto,
      );
    },
  );

  Widget _compactList(BuildContext context) {
    final c = context.colors;
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: vertical ? 6 : 10,
        vertical: vertical ? 6 : 0,
      ),
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      itemCount: topics.length + 1,
      itemBuilder: (context, index) {
        final topic = index == 0 ? null : topics[index - 1];
        final selected = topic?.id == selectedTopicId;
        final name =
            topic?.name ?? AppStringKeys.topicChatAllFilter.l10n(context);
        final iconId = topic?.iconCustomEmojiId ?? 0;
        final rawColor = topic?.iconColor ?? 0;
        final color = selected
            ? AppTheme.brand
            : rawColor == 0
            ? c.textSecondary
            : Color(0xFF000000 | (rawColor & 0xFFFFFF));
        return Semantics(
          button: true,
          selected: selected,
          label: name,
          child: GestureDetector(
            key: ValueKey('topic-navigation-item-${topic?.id ?? "all"}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelected(topic?.id),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: vertical && selected ? c.searchFill : null,
                borderRadius: vertical
                    ? BorderRadius.circular(AppRadius.control)
                    : null,
                border: !vertical && selected
                    ? Border(
                        bottom: BorderSide(color: AppTheme.brand, width: 3),
                      )
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (iconId != 0)
                    CustomEmojiView(id: iconId)
                  else
                    AppIcon(HeroAppIcons.hashtag, color: color, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected ? AppTheme.brand : c.textPrimary,
                      ),
                    ),
                  ),
                  if (topic != null && topic.unreadCount > 0) ...[
                    const SizedBox(width: 6),
                    UnreadBadge(
                      key: ValueKey('topic-navigation-unread-${topic.id}'),
                      count: topic.unreadCount,
                      muted: topic.isMuted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The vertical rail's header: Telegram iOS puts topic creation in the topic
/// list's own header, so the '+' lives above the rows here. The same header
/// carries the bulk "mark all topics read" action while anything is unread.
class _RailHeader extends StatelessWidget {
  const _RailHeader({this.onCreateTopic, this.onMarkAllRead});

  final VoidCallback? onCreateTopic;
  final VoidCallback? onMarkAllRead;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                AppStringKeys.groupAdministrationForumTopics.l10n(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          if (onMarkAllRead != null)
            Semantics(
              button: true,
              label: AppStringKeys.topicChatMarkAllRead.l10n(context),
              child: GestureDetector(
                key: const ValueKey('topic-list-mark-all-read'),
                behavior: HitTestBehavior.opaque,
                onTap: onMarkAllRead,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: AppIcon(
                    HeroAppIcons.circleCheck,
                    size: 20,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ),
          if (onCreateTopic != null)
            GestureDetector(
              key: const ValueKey('topic-list-create'),
              behavior: HitTestBehavior.opaque,
              onTap: onCreateTopic,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.md,
                  right: AppSpacing.lg,
                  top: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                ),
                child: AppIcon(
                  HeroAppIcons.plus,
                  size: 20,
                  color: AppTheme.brand,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Remembers each chat's tab-strip scroll offset across transcript swaps.
/// Opening a topic replaces the whole ChatView (its state reads the topic
/// once), so the fresh strip rebuilds at offset 0 without this — shifting
/// the tabs the user was looking at. Keyed by chat, never cleared: it is a
/// few floats per forum chat.
class TopicTabStripScrollMemory {
  TopicTabStripScrollMemory._();

  static final Map<int, double> _offsets = {};

  static double? read(int chatId) => _offsets[chatId];

  static void write(int chatId, double offset) {
    // Guard degenerate extents before the list has laid out.
    if (!offset.isFinite || offset < 0) return;
    _offsets[chatId] = offset;
  }

  /// Drops every remembered offset. Tests only.
  @visibleForTesting
  static void resetForTesting() => _offsets.clear();
}

/// Applies one drag in pinned-tab reorder mode. ReorderableListView's
/// `onReorderItem` has already adjusted [newIndex] for the removal, so the id
/// list is simply moved; out-of-range indices leave it untouched.
List<int> reorderPinnedTopicIds(List<int> ids, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= ids.length) return ids;
  final next = List<int>.of(ids);
  final moved = next.removeAt(oldIndex);
  next.insert(newIndex.clamp(0, next.length), moved);
  return next;
}

/// The topic tab strip: a horizontal, folder-tab-styled selector pinned
/// under the chat header for forum groups and bot topic chats on narrow
/// layouts. Mirrors the chat list's folder tabs — label with the topic
/// icon, unread badge pill, and the 4pt selection indicator under the
/// chosen tab. Switching topics must not move the strip: the scroll offset
/// lives in [TopicTabStripScrollMemory] and survives the transcript swap.
class TopicTabStrip extends StatefulWidget {
  const TopicTabStrip({
    super.key,
    required this.chatId,
    required this.topics,
    required this.selectedTopicId,
    required this.onSelected,
    this.showUnreadBadges = true,
    this.badgeOverflowLabel,
    this.isLoading = false,
    this.onLongPress,
    this.placement = TopicTabsPlacement.top,
    this.onTogglePlacement,
    this.reordering = false,
    this.onReorder,
    this.onReorderDone,
  });

  /// The chat whose topics these are; keys the scroll-offset memory.
  final int chatId;

  final List<TopicNavigationItem> topics;

  /// The open transcript's topic id; null = the "All" pseudo-topic.
  final int? selectedTopicId;
  final ValueChanged<int?> onSelected;

  /// Folder-tab badge parity: honours the chat-list unread-badge setting.
  final bool showUnreadBadges;

  /// Pre-formatted count text for [topics]' total unread; when null the strip
  /// derives per-topic labels itself (capped at 99+).
  final String? Function(int count)? badgeOverflowLabel;

  /// Shows the trailing shimmer tab while a topic page is still in flight.
  final bool isLoading;

  /// Long press on a real topic tab, with the tab's global rect as the
  /// anchor for the host's topic menu. The "All" pseudo-tab never fires it.
  final void Function(TopicNavigationItem topic, Rect anchor)? onLongPress;

  /// Where the strip sits in the conversation. Only changes the icon and the
  /// toggle's own semantics: the host owns the actual placement.
  final TopicTabsPlacement placement;

  /// Moves the strip between the top of the conversation and the composer,
  /// the way exteraless's tabs toggle does. Null hides the control.
  final VoidCallback? onTogglePlacement;

  /// Pinned-tab reorder mode (exteraless's FilterReorder): only the pinned
  /// topics are draggable, and the ordering is persisted server-side by the
  /// host's [onReorder].
  final bool reordering;
  final ValueChanged<List<int>>? onReorder;
  final VoidCallback? onReorderDone;

  @override
  State<TopicTabStrip> createState() => _TopicTabStripState();
}

class _TopicTabStripState extends State<TopicTabStrip> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: TopicTabStripScrollMemory.read(widget.chatId) ?? 0,
    );
    _controller.addListener(_rememberOffset);
  }

  @override
  void dispose() {
    _rememberOffset();
    _controller.dispose();
    super.dispose();
  }

  void _rememberOffset() {
    if (!_controller.hasClients) return;
    TopicTabStripScrollMemory.write(widget.chatId, _controller.offset);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tabHeight = AppMetric.rowExtentFor(
      context,
      base: 44,
      lines: const [AppTextSize.callout],
    );
    final topics = widget.topics;
    final isLoading = widget.isLoading;
    final reordering = widget.reordering;
    final pinned = [
      for (final topic in topics)
        if (topic.isPinned) topic,
    ];
    // The strip scrolls horizontally, so a rightward drag on it means "show
    // earlier tabs" — never the page's back swipe. Keep the whole bar out of
    // that gesture, including the gaps between tabs.
    return ExcludeFromBackSwipe(
      child: Container(
        width: double.infinity,
        height: tabHeight,
        decoration: BoxDecoration(
          // Same bar as the chat header so the strip reads as part of the
          // header, not a separate washed panel.
          color: c.navBar,
          border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            // exteraless puts the position control inside the tab bar; tabs
            // stay on top until the reader moves them above the composer.
            if (!reordering && widget.onTogglePlacement != null)
              _TopicTabsPlacementToggle(
                placement: widget.placement,
                onTap: widget.onTogglePlacement!,
              ),
            Expanded(
              child: reordering
                  ? _reorderList(pinned)
                  : ListView.separated(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      itemCount: topics.length + 1 + (isLoading ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(width: 28),
                      itemBuilder: (context, index) {
                        // Index 0 is the "All" tab; topics occupy
                        // 1..topics.length, and the loading placeholder is the
                        // LAST slot. Getting this off by one reads topics[-1]
                        // on an empty page and Flutter swaps in an error box,
                        // which release builds paint as an opaque grey block
                        // over the strip's right side.
                        if (isLoading && index == topics.length + 1) {
                          // Topic info is still loading: the placeholder tab
                          // keeps the same bar color as the header so the
                          // strip reads as one unified surface instead of a
                          // grey block sticking out.
                          return SizedBox(height: tabHeight);
                        }
                        final all = index == 0;
                        final topic = all ? null : topics[index - 1];
                        final selected = all
                            ? widget.selectedTopicId == null
                            : topic!.id == widget.selectedTopicId;
                        return _TopicTab(
                          key: ValueKey('topic-tab-${topic?.id ?? "all"}'),
                          topic: topic,
                          selected: selected,
                          showUnreadBadge: widget.showUnreadBadges,
                          badgeOverflowLabel: widget.badgeOverflowLabel,
                          onTap: () => widget.onSelected(topic?.id),
                          onLongPress: topic == null
                              ? null
                              : (anchor) =>
                                    widget.onLongPress?.call(topic, anchor),
                        );
                      },
                    ),
            ),
            if (reordering && widget.onReorderDone != null)
              _TopicTabsReorderDoneButton(onTap: widget.onReorderDone!),
          ],
        ),
      ),
    );
  }

  /// Reorder mode (exteraless's FilterReorder): only pinned topics move, and
  /// the order is the pin order the server stores. Long-press-to-drag keeps
  /// the bar scrollable while a long strip is being rearranged.
  Widget _reorderList(List<TopicNavigationItem> pinned) {
    return ReorderableListView.builder(
      key: const ValueKey('topic-tabs-reorder'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      buildDefaultDragHandles: false,
      itemCount: pinned.length,
      onReorderItem: (oldIndex, newIndex) {
        widget.onReorder?.call(
          reorderPinnedTopicIds(
            [for (final topic in pinned) topic.id],
            oldIndex,
            newIndex,
          ),
        );
      },
      itemBuilder: (context, index) {
        final topic = pinned[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('topic-tab-reorder-${topic.id}'),
          index: index,
          child: Padding(
            padding: EdgeInsets.only(
              right: index == pinned.length - 1 ? 0 : 28,
            ),
            child: _TopicTab(
              topic: topic,
              selected: topic.id == widget.selectedTopicId,
              showUnreadBadge: widget.showUnreadBadges,
              badgeOverflowLabel: widget.badgeOverflowLabel,
              onTap: () => widget.onSelected(topic.id),
            ),
          ),
        );
      },
    );
  }
}

/// exteraless's side tabs — the `VerticalTabView` column inside
/// `TopicsTabsView`: a 64dp strip docked at the conversation's left edge with
/// the topic glyph over up to three lines of its name, the unread pill on the
/// glyph's top-right corner and a brand bar on the selected row's left edge.
/// The host puts the transcript beside it, so the chat is pushed right by the
/// bar's width the way the reference client offsets its message list.
class TopicTabsSideBar extends StatefulWidget {
  const TopicTabsSideBar({
    super.key,
    required this.chatId,
    required this.topics,
    required this.selectedTopicId,
    required this.onSelected,
    this.showUnreadBadges = true,
    this.badgeOverflowLabel,
    this.isLoading = false,
    this.onLongPress,
    this.onTogglePlacement,
    this.reordering = false,
    this.onReorder,
    this.onReorderDone,
  });

  /// exteraless's `SIDE_TABS_WIDTH`.
  static const double barWidth = 64;

  /// The chat whose topics these are; keys the scroll-offset memory.
  final int chatId;

  final List<TopicNavigationItem> topics;

  /// The open transcript's topic id; null = the "All" pseudo-topic.
  final int? selectedTopicId;
  final ValueChanged<int?> onSelected;

  /// Folder-tab badge parity: honours the chat-list unread-badge setting.
  final bool showUnreadBadges;
  final String? Function(int count)? badgeOverflowLabel;
  final bool isLoading;

  /// Long press on a real topic tab, with the tab's global rect as the anchor
  /// for the host's topic menu. The "All" pseudo-tab never fires it.
  final void Function(TopicNavigationItem topic, Rect anchor)? onLongPress;

  /// Moves the bar to its next home (side → bottom). Null hides the control.
  final VoidCallback? onTogglePlacement;

  /// Pinned-tab reorder mode, shared with the horizontal strip.
  final bool reordering;
  final ValueChanged<List<int>>? onReorder;
  final VoidCallback? onReorderDone;

  @override
  State<TopicTabsSideBar> createState() => _TopicTabsSideBarState();
}

class _TopicTabsSideBarState extends State<TopicTabsSideBar> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final topics = widget.topics;
    final isLoading = widget.isLoading;
    final reordering = widget.reordering;
    final pinned = [
      for (final topic in topics)
        if (topic.isPinned) topic,
    ];
    return Container(
      key: const ValueKey('topic-tabs-side-bar'),
      width: TopicTabsSideBar.barWidth,
      decoration: BoxDecoration(
        color: c.navBar,
        border: Border(right: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Center(
              child: reordering && widget.onReorderDone != null
                  ? _TopicTabsReorderDoneButton(
                      onTap: widget.onReorderDone!,
                      compact: true,
                    )
                  : widget.onTogglePlacement == null
                  ? null
                  : _TopicTabsPlacementToggle(
                      placement: TopicTabsPlacement.side,
                      onTap: widget.onTogglePlacement!,
                      width: TopicTabsSideBar.barWidth,
                    ),
            ),
          ),
          Expanded(
            child: reordering
                ? _reorderList(pinned)
                : ListView.builder(
                    key: const ValueKey('topic-tabs-side-list'),
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    itemCount: topics.length + 1 + (isLoading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (isLoading && index == topics.length + 1) {
                        // The strip keeps a quiet slot while the first topic
                        // page is in flight instead of jumping when it lands.
                        return const SizedBox(height: 56);
                      }
                      final all = index == 0;
                      final topic = all ? null : topics[index - 1];
                      return _SideTopicTab(
                        key: ValueKey('topic-tab-${topic?.id ?? "all"}'),
                        topic: topic,
                        selected: all
                            ? widget.selectedTopicId == null
                            : topic!.id == widget.selectedTopicId,
                        showUnreadBadge: widget.showUnreadBadges,
                        badgeOverflowLabel: widget.badgeOverflowLabel,
                        onTap: () => widget.onSelected(topic?.id),
                        onLongPress: topic == null
                            ? null
                            : (anchor) =>
                                  widget.onLongPress?.call(topic, anchor),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// The vertical counterpart of the strip's reorder list: pinned topics
  /// only, long-press to drag so the column stays scrollable.
  Widget _reorderList(List<TopicNavigationItem> pinned) {
    return ReorderableListView.builder(
      key: const ValueKey('topic-tabs-side-reorder'),
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      buildDefaultDragHandles: false,
      itemCount: pinned.length,
      onReorderItem: (oldIndex, newIndex) {
        widget.onReorder?.call(
          reorderPinnedTopicIds(
            [for (final topic in pinned) topic.id],
            oldIndex,
            newIndex,
          ),
        );
      },
      itemBuilder: (context, index) {
        final topic = pinned[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('topic-tab-reorder-${topic.id}'),
          index: index,
          child: _SideTopicTab(
            topic: topic,
            selected: topic.id == widget.selectedTopicId,
            showUnreadBadge: widget.showUnreadBadges,
            badgeOverflowLabel: widget.badgeOverflowLabel,
            onTap: () => widget.onSelected(topic.id),
          ),
        );
      },
    );
  }
}

/// One row of the side bar: a 64dp column holding the glyph (custom emoji or
/// hashtag) with the unread pill, the topic name in up to three lines, and
/// the brand bar on the selected row's left edge.
class _SideTopicTab extends StatelessWidget {
  const _SideTopicTab({
    super.key,
    required this.topic,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.showUnreadBadge = true,
    this.badgeOverflowLabel,
  });

  final TopicNavigationItem? topic;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Rect>? onLongPress;
  final bool showUnreadBadge;
  final String? Function(int count)? badgeOverflowLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAll = topic == null;
    final name = isAll
        ? AppStringKeys.topicChatAllFilter.l10n(context)
        : topic!.name;
    final unread = topic?.unreadCount ?? 0;
    final iconId = topic?.iconCustomEmojiId ?? 0;
    final rawColor = topic?.iconColor ?? 0;
    final iconColor = selected
        ? AppTheme.brand
        : rawColor == 0
        ? c.textSecondary
        : Color(0xFF000000 | (rawColor & 0xFFFFFF));
    final longPress = onLongPress;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: longPress == null
            ? null
            : () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                longPress(box.localToGlobal(Offset.zero) & box.size);
              },
        child: Stack(
          children: [
            if (selected)
              Positioned(
                left: 0,
                top: AppSpacing.sm,
                bottom: AppSpacing.sm,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: AppTheme.brand,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(AppRadius.sm),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 34,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        if (iconId != 0)
                          CustomEmojiView(id: iconId, size: 26)
                        else
                          AppIcon(
                            isAll ? HeroAppIcons.inbox : HeroAppIcons.hashtag,
                            size: 26,
                            color: iconColor,
                          ),
                        if (showUnreadBadge && !isAll && unread > 0)
                          Positioned(
                            top: -2,
                            right: AppSpacing.xs,
                            child: FolderUnreadBadge(
                              key: ValueKey('topic-tab-unread-${topic!.id}'),
                              label: _badgeLabel(unread),
                              accent: !topic!.isMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTextSize.tiny,
                      height: 1.15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? AppTheme.brand : c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _badgeLabel(int count) {
    final custom = badgeOverflowLabel?.call(count);
    if (custom != null) return custom;
    return count > 99 ? '99+' : '$count';
  }
}

/// The move control's label for what the NEXT tap does, mirroring
/// exteraless's top → side → bottom → top cycle.
String topicTabsMoveLabelKey(TopicTabsPlacement placement) =>
    switch (nextTopicTabsPlacement(placement)) {
      TopicTabsPlacement.top => AppStringKeys.mithkaxTopicTabsMoveToTop,
      TopicTabsPlacement.side => AppStringKeys.mithkaxTopicTabsMoveToSide,
      TopicTabsPlacement.bottom => AppStringKeys.mithkaxTopicTabsMoveToBottom,
    };

/// The glyph for the move control, from the same cycle: left for the side,
/// down for the composer, up for the header.
AppIconData topicTabsMoveIcon(TopicTabsPlacement placement) =>
    switch (nextTopicTabsPlacement(placement)) {
      TopicTabsPlacement.top => HeroAppIcons.arrowUp,
      TopicTabsPlacement.side => HeroAppIcons.arrowLeft,
      TopicTabsPlacement.bottom => HeroAppIcons.arrowDown,
    };

/// The placement control: the reference client's sidebar button. Tapping it
/// walks the tabs through top → side → bottom → top, so the glyph always
/// names the next home.
class _TopicTabsPlacementToggle extends StatelessWidget {
  const _TopicTabsPlacementToggle({
    required this.placement,
    required this.onTap,
    this.width = 44,
  });

  final TopicTabsPlacement placement;
  final VoidCallback onTap;

  /// 44 in the horizontal bar, 64 on the side bar's own header slot.
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: topicTabsMoveLabelKey(placement).l10n(context),
      child: GestureDetector(
        key: const ValueKey('topic-tabs-placement-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Center(
            child: AppIcon(
              topicTabsMoveIcon(placement),
              size: 18,
              color: context.colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Closes reorder mode, the check exteraless hangs at the bar's trailing edge.
/// [compact] keeps it inside the 64dp side bar: glyph only, no label.
class _TopicTabsReorderDoneButton extends StatelessWidget {
  const _TopicTabsReorderDoneButton({
    required this.onTap,
    this.compact = false,
  });

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AppStringKeys.mithkaxTopicTabsDone.l10n(context),
      child: GestureDetector(
        key: const ValueKey('topic-tabs-reorder-done'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 0 : AppSpacing.md,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(HeroAppIcons.check, size: 18, color: AppTheme.brand),
              if (!compact) ...[
                const SizedBox(width: 4),
                Text(
                  AppStringKeys.mithkaxTopicTabsDone.l10n(context),
                  style: TextStyle(
                    fontSize: AppTextSize.callout,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.brand,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicTab extends StatelessWidget {
  const _TopicTab({
    super.key,
    required this.topic,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.showUnreadBadge = true,
    this.badgeOverflowLabel,
  });

  final TopicNavigationItem? topic;
  final bool selected;
  final VoidCallback onTap;

  /// Reports the tab's global rect so the host can hang its menu there.
  final ValueChanged<Rect>? onLongPress;
  final bool showUnreadBadge;
  final String? Function(int count)? badgeOverflowLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAll = topic == null;
    final name = isAll
        ? AppStringKeys.topicChatAllFilter.l10n(context)
        : topic!.name;
    final unread = topic?.unreadCount ?? 0;
    final iconId = topic?.iconCustomEmojiId ?? 0;
    final rawColor = topic?.iconColor ?? 0;
    final iconColor = selected
        ? AppTheme.brand
        : rawColor == 0
        ? c.textSecondary
        : Color(0xFF000000 | (rawColor & 0xFFFFFF));
    final longPress = onLongPress;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: longPress == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              longPress(box.localToGlobal(Offset.zero) & box.size);
            },
      child: SizedBox(
        height: 44,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (iconId != 0)
                  CustomEmojiView(id: iconId, size: 17)
                else
                  AppIcon(
                    isAll ? HeroAppIcons.inbox : HeroAppIcons.hashtag,
                    size: 17,
                    color: iconColor,
                  ),
                const SizedBox(width: AppSpacing.xs + 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 168),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTextSize.callout,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                ),
                if (showUnreadBadge && !isAll && unread > 0) ...[
                  const SizedBox(width: 5),
                  FolderUnreadBadge(
                    key: ValueKey('topic-tab-unread-${topic!.id}'),
                    label: _badgeLabel(unread),
                    accent: !topic!.isMuted,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 7),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: selected ? 1 : 0),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _badgeLabel(int count) {
    final custom = badgeOverflowLabel?.call(count);
    if (custom != null) return custom;
    return count > 99 ? '99+' : '$count';
  }
}
