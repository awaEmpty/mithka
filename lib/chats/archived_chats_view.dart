//
//  archived_chats_view.dart
//
//  Telegram archived chats folded behind the group assistant entry.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/platform/app_haptics.dart';

import '../app/app_navigator.dart';
import '../app/ipad_window_chrome.dart';
import '../chat/chat_view.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/desktop_row_actions.dart';
import '../platform/adaptive_platform.dart';
import '../platform/system_ui.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';
import 'chat_list_view.dart' show ChatListSelectionHighlight;
import 'chat_list_view_model.dart';
import 'chat_row_view.dart';
import 'chat_selection_actions.dart';
import 'chat_selection_header.dart';

/// The archive/assistant avatar's amber. Also the tone of the pull-down
/// reveal's inner glow, so the bloom reads as light coming off that avatar.
const Color archivedChatsAccent = Color(0xFFFF9D2E);

class ArchivedChatsRow extends StatelessWidget {
  const ArchivedChatsRow({
    super.key,
    required this.archived,
    this.onClearUnread,
  });
  final List<ChatSummary> archived;
  final VoidCallback? onClearUnread;

  ChatSummary? get _latest => archived.isEmpty ? null : archived.first;
  int get _totalUnread => archived.fold(0, (a, c) => a + c.unreadCount);

  ChatSummary get summary {
    final latest = _latest;
    final title = AppStrings.t(AppStringKeys.archivedChatsGroupAssistant);
    return ChatSummary(
      id: 0,
      title: title,
      lastMessage: latest?.lastMessage ?? '',
      lastMessageId: latest?.lastMessageId ?? 0,
      date: latest?.date ?? 0,
      unreadCount: _totalUnread,
      order: latest?.order ?? 0,
      isMuted: true,
      lastSender: latest?.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    return ChatRowView(
      chat: summary,
      archived: true,
      onClearUnread: onClearUnread,
      avatarBuilder: (size) => Container(
        key: const ValueKey('archived-chats-avatar'),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: archivedChatsAccent,
          shape: BoxShape.circle,
        ),
        child: const AppIcon(
          HeroAppIcons.solidMessage,
          size: 48 * 0.46,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// [ArchivedChatsView] bound to the live chat-list model.
///
/// The split layout swaps only the list pane and leaves the chat list mounted
/// behind it, while a pushed route owns the whole screen; both read the same
/// model, so an unarchive (or a cleared badge) lands in either presentation.
class LiveArchivedChatsView extends StatelessWidget {
  const LiveArchivedChatsView({
    super.key,
    required this.model,
    this.onBack,
    this.onChatSelected,
    this.selectedChatId,
  });

  final ChatListViewModel model;
  final VoidCallback? onBack;
  final ValueChanged<ChatSummary>? onChatSelected;
  final int? selectedChatId;

  @override
  Widget build(BuildContext context) => ArchivedChatsView(
    model: model,
    onBack: onBack,
    onChatSelected: onChatSelected,
    selectedChatId: selectedChatId,
  );
}

/// The archived list, with the same long-press edit mode the reference client gives its
/// archive folder (a DialogsActivity with folderId=1 runs the identical action
/// mode): a body long press selects, the header becomes a command bar, and
/// every command maps onto the archive's own row actions.
class ArchivedChatsView extends StatefulWidget {
  const ArchivedChatsView({
    super.key,
    required this.model,
    this.onBack,
    this.onChatSelected,
    this.selectedChatId,
  });
  final ChatListViewModel model;
  final VoidCallback? onBack;
  final ValueChanged<ChatSummary>? onChatSelected;
  final int? selectedChatId;

  @override
  State<ArchivedChatsView> createState() => _ArchivedChatsViewState();
}

class _ArchivedChatsViewState extends State<ArchivedChatsView> {
  final Set<int> _selectedChatIds = {};
  final GlobalKey<ChatSelectionHeaderState> _selectionHeaderKey =
      GlobalKey<ChatSelectionHeaderState>();

  bool get _selectionMode => _selectedChatIds.isNotEmpty;

  List<ChatSummary> get _chats => widget.model.archived;

  List<ChatSummary> get _selectedChats =>
      _chats.where((chat) => _selectedChatIds.contains(chat.id)).toList();

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_handleModelChanged);
  }

  @override
  void didUpdateWidget(covariant ArchivedChatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    oldWidget.model.removeListener(_handleModelChanged);
    widget.model.addListener(_handleModelChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_handleModelChanged);
    super.dispose();
  }

  /// The archive can empty out from under an open edit mode (a batch
  /// unarchive); a selection that no longer exists must not keep the bar up.
  void _handleModelChanged() {
    if (!mounted) return;
    if (_selectionMode) {
      final alive = _chats.map((chat) => chat.id).toSet();
      if (!_selectedChatIds.any(alive.contains)) {
        setState(_selectedChatIds.clear);
        return;
      }
    }
    setState(() {});
  }

  void _beginSelection(ChatSummary chat) {
    unawaited(AppHaptics.longPress());
    setState(() => _selectedChatIds.add(chat.id));
  }

  void _exitSelection() {
    setState(_selectedChatIds.clear);
  }

  void _toggleSelected(ChatSummary chat) => setState(() {
    if (!_selectedChatIds.add(chat.id)) _selectedChatIds.remove(chat.id);
  });

  void _selectAllVisible() {
    setState(() {
      for (final chat in _chats) {
        _selectedChatIds.add(chat.id);
      }
    });
  }

  void _runOverSelection(void Function(ChatSummary chat) action) {
    final chats = _selectedChats;
    _exitSelection();
    for (final chat in chats) {
      action(chat);
    }
  }

  Future<void> _deleteSelection() async {
    final chats = _selectedChats;
    if (chats.isEmpty) return;
    final deleted = await deleteChatSelection(context, widget.model, chats);
    if (mounted && deleted) _exitSelection();
  }

  Future<void> _clearHistorySelection() async {
    final chats = _selectedChats;
    if (chats.isEmpty) return;
    final cleared = await clearChatSelectionHistory(
      context,
      widget.model,
      chats,
    );
    if (mounted && cleared) _exitSelection();
  }

  Future<void> _blockSelection() async {
    final chats = _selectedChats;
    if (chats.isEmpty) return;
    final blocked = await blockChatSelection(context, chats);
    if (mounted && blocked) _exitSelection();
  }

  void _addToFolderSelection() {
    final chats = _selectedChats;
    if (chats.isEmpty) return;
    final anchor = _selectionHeaderKey.currentState?.overflowButtonRect();
    _exitSelection();
    unawaited(
      addChatSelectionToFolder(context, widget.model, chats, anchor: anchor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selectionMode = _selectionMode;
    return PopScope(
      canPop: !selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: Column(
          children: [
            if (selectionMode) _selectionHeader(context) else _normalHeader(),
            Expanded(child: _chatsList(context, selectionMode: selectionMode)),
          ],
        ),
      ),
    );
  }

  Widget _chatsList(BuildContext context, {required bool selectionMode}) {
    final chats = _chats;
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: chats.length,
      itemBuilder: (context, i) {
        final chat = chats[i];
        return _ArchivedChatSwipeRow(
          key: ValueKey(chat.id),
          chat: chat,
          selected: chat.id == widget.selectedChatId,
          selectionTint: _selectedChatIds.contains(chat.id),
          onTap: () =>
              selectionMode ? _toggleSelected(chat) : _openChat(context, chat),
          onLongPress: () =>
              selectionMode ? _toggleSelected(chat) : _beginSelection(chat),
          onClearUnread: () => widget.model.markRead(chat),
          onUnarchive: () => widget.model.unarchive(chat),
        );
      },
    );
  }

  /// The archive's own header, pinned to the chat list's height.
  ///
  /// The archive is a chat list, not a settings subpage: exteraless draws the
  /// same ActionBar there as on the main list. A stock NavHeader is 28pt
  /// shorter, so opening edit mode shoved the list down and the two screens
  /// read as different surfaces. Same chrome padding, same hit-target row,
  /// same fill as the chat list's header — only the title differs.
  Widget _normalHeader() {
    final c = context.colors;
    final pointerDense = isDesktopTargetPlatform();
    final title = AppStrings.t(AppStringKeys.archivedChatsGroupAssistant);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiOverlayStyleForSurface(c.listHeaderTint),
      child: Container(
        key: const ValueKey('archived-chats-header'),
        color: c.listHeaderTint,
        padding: headerChromePaddingOf(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md + AppSpacing.xxs,
          ),
          child: SizedBox(
            height: AppMetric.chatHeaderHitTarget(),
            child: Row(
              children: [
                AppInteractiveSurface(
                  key: const ValueKey('archived-chats-back'),
                  semanticLabel: AppStringKeys.navigationBack.l10n(context),
                  onTap: widget.onBack ?? () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: AppMetric.chatHeaderHitTarget(),
                    height: AppMetric.chatHeaderHitTarget(),
                    child: Center(
                      child: AppIcon(
                        HeroAppIcons.chevronLeft,
                        size: pointerDense ? AppIconSize.lg : AppIconSize.nav,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: pointerDense
                        ? AppTextStyle.bodyLarge(
                            c.textPrimary,
                            weight: AppTextWeight.medium,
                          )
                        : AppTextStyle.title(c.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The same command bar the main list shows (one shared widget, so the two
  /// are the same height and draw the same glyphs), carrying the archive's own
  /// actions: unarchive and the archive list's pin sit where the main list has
  /// archive and pin.
  Widget _selectionHeader(BuildContext context) {
    final chats = _selectedChats;
    final allPinned =
        chats.isNotEmpty && chats.every(widget.model.isPinnedInArchive);
    final allMuted = chats.isNotEmpty && chats.every((chat) => chat.isMuted);
    final anyUnread = chats.any(
      (chat) => chat.unreadCount > 0 || chat.isMarkedUnread,
    );
    final folders = [
      for (final filter in widget.model.filters)
        if (!filter.isAll && filter.folderId != null) filter,
    ];
    return ChatSelectionHeader(
      key: _selectionHeaderKey,
      count: _selectedChatIds.length,
      onClose: _exitSelection,
      commands: [
        ChatSelectionCommand(
          id: 'unarchive',
          label: AppStrings.t(AppStringKeys.chatListUnarchive),
          icon: HeroAppIcons.inbox,
          onTap: () =>
              _runOverSelection((chat) => widget.model.unarchive(chat)),
        ),
        ChatSelectionCommand(
          id: 'pin',
          label: AppStrings.t(
            allPinned ? AppStringKeys.chatListUnpin : AppStringKeys.chatInfoPin,
          ),
          icon: HeroAppIcons.pin,
          onTap: () {
            final pin = !allPinned;
            _runOverSelection((chat) {
              if (widget.model.isPinnedInArchive(chat) != pin) {
                widget.model.toggleArchivePin(chat);
              }
            });
          },
        ),
        ChatSelectionCommand(
          id: 'mute',
          label: AppStrings.t(
            allMuted ? AppStringKeys.chatUnmute : AppStringKeys.callMute,
          ),
          icon: allMuted ? HeroAppIcons.bell : HeroAppIcons.bellSlash,
          onTap: () {
            final mute = !allMuted;
            _runOverSelection((chat) {
              if (chat.isMuted != mute) widget.model.toggleMute(chat);
            });
          },
        ),
        ChatSelectionCommand(
          id: 'delete',
          label: AppStrings.t(AppStringKeys.chatDelete),
          icon: HeroAppIcons.trash,
          destructive: true,
          onTap: () => unawaited(_deleteSelection()),
        ),
      ],
      overflow: [
        ChatSelectionCommand(
          id: 'read',
          label: AppStrings.t(
            anyUnread
                ? AppStringKeys.channelDirectMessagesMarkRead
                : AppStringKeys.chatListMarkUnread,
          ),
          icon: anyUnread ? HeroAppIcons.circleCheck : HeroAppIcons.eyeSlash,
          onTap: () {
            toggleChatSelectionRead(widget.model, chats);
            _exitSelection();
          },
        ),
        ChatSelectionCommand(
          id: 'clear-history',
          label: AppStrings.t(AppStringKeys.chatInfoClearHistory),
          icon: HeroAppIcons.circleMinus,
          onTap: () => unawaited(_clearHistorySelection()),
        ),
        if (chatSelectionAllBlockable(chats))
          ChatSelectionCommand(
            id: 'block',
            label: AppStrings.t(AppStringKeys.chatListBlockUser),
            icon: HeroAppIcons.ban,
            destructive: true,
            onTap: () => unawaited(_blockSelection()),
          ),
        if (folders.isNotEmpty)
          ChatSelectionCommand(
            id: 'add-to-folder',
            label: AppStrings.t(AppStringKeys.chatListAddToFolder),
            icon: HeroAppIcons.folder,
            onTap: _addToFolderSelection,
          ),
        ChatSelectionCommand(
          id: 'select-all',
          label: AppStrings.t(AppStringKeys.chatListSelectAll),
          icon: HeroAppIcons.check,
          onTap: _selectAllVisible,
        ),
      ],
    );
  }

  void _openChat(BuildContext context, ChatSummary chat) {
    final selectionHandler = widget.onChatSelected;
    if (selectionHandler != null) {
      selectionHandler(chat);
      return;
    }
    pushAppChatRoute(
      context,
      AppChatPageRoute(
        builder: (_) => ChatView(chatId: chat.id, title: chat.title),
      ),
    );
  }
}

class _ArchivedChatSwipeRow extends StatefulWidget {
  const _ArchivedChatSwipeRow({
    super.key,
    required this.chat,
    required this.selected,
    required this.onTap,
    required this.onClearUnread,
    this.onUnarchive,
    this.onLongPress,
    this.selectionTint = false,
  });

  final ChatSummary chat;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClearUnread;
  final VoidCallback? onUnarchive;
  final VoidCallback? onLongPress;

  /// Edit-mode membership tint, drawn over the row like the main list.
  final bool selectionTint;

  @override
  State<_ArchivedChatSwipeRow> createState() => _ArchivedChatSwipeRowState();
}

class _ArchivedChatSwipeRowState extends State<_ArchivedChatSwipeRow> {
  static const _actionWidth = 92.0;
  double _offset = 0;

  @override
  Widget build(BuildContext context) {
    final action = widget.onUnarchive;
    final row = ChatRowView(
      chat: widget.chat,
      archived: true,
      selected: widget.selected,
      onClearUnread: widget.onClearUnread,
    );
    final tintedRow = widget.selectionTint
        ? ChatListSelectionHighlight(selected: true, child: row)
        : row;
    // Match the main list: macOS uses secondary-click commands, never a
    // horizontal swipe tray (including trackpad drags).
    if (!kIsWeb && Theme.of(context).platform == TargetPlatform.macOS) {
      return DesktopRowActionRegion(
        actions: [
          if (action != null)
            DesktopRowAction(
              id: 'unarchive',
              label: AppStringKeys.chatListUnarchive,
              icon: HeroAppIcons.inbox,
              onInvoke: action,
            ),
          if (widget.chat.unreadCount > 0 || widget.chat.isMarkedUnread)
            DesktopRowAction(
              id: 'mark-read',
              label: AppStringKeys.channelDirectMessagesMarkRead,
              icon: HeroAppIcons.circleCheck,
              onInvoke: widget.onClearUnread,
            ),
        ],
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: tintedRow,
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _offset == 0 ? widget.onTap : () => setState(() => _offset = 0),
      onLongPress: widget.selectionTint || _offset == 0
          ? widget.onLongPress
          : null,
      onHorizontalDragUpdate: action == null
          ? null
          : (details) => setState(() {
              _offset = (_offset + details.delta.dx).clamp(-_actionWidth, 0);
            }),
      onHorizontalDragEnd: action == null
          ? null
          : (_) => setState(
              () => _offset = _offset <= -_actionWidth / 2 ? -_actionWidth : 0,
            ),
      child: ClipRect(
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            if (action != null && _offset != 0)
              Positioned(
                key: const ValueKey('archived-chat-unarchive'),
                top: 0,
                bottom: 0,
                right: 0,
                width: _actionWidth,
                child: ColoredBox(
                  color: AppTheme.brand,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      action();
                      setState(() => _offset = 0);
                    },
                    child: const Center(
                      child: AppIcon(
                        HeroAppIcons.inbox,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(_offset, 0),
              child: ColoredBox(
                color: context.colors.background,
                child: tintedRow,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
