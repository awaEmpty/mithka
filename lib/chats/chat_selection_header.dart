//
//  chat_selection_header.dart
//
//  The chat list's edit-mode command bar (exteraless's dialog action mode):
//  a close button, the selected-chat count, the direct icon commands and an
//  overflow column for the less frequent ones.
//
//  One widget serves the main list and the archive page. exteraless runs the
//  same action mode for both (its archive is just a folder), so the two bars
//  must be the same height, draw the same 24px glyphs and open the same
//  anchored overflow popup — otherwise entering edit mode in the archive
//  reads as a different, smaller control.
//

import 'package:flutter/material.dart';
import '../app/ipad_window_chrome.dart';
import '../components/anchored_menu_overlay.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// One command in the edit-mode bar or in its overflow column.
class ChatSelectionCommand {
  const ChatSelectionCommand({
    required this.id,
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  /// Stable suffix for the control's key: `chat-list-selection-<id>` for a
  /// direct command, `chat-list-selection-overflow-<id>` for an overflow row.
  final String id;

  /// Already localized label (also the control's semantic name).
  final String label;

  final AppIconData icon;
  final VoidCallback onTap;

  /// Destructive commands render in the danger color.
  final bool destructive;
}

/// The edit-mode header: close, count, direct commands, overflow column.
///
/// The bar occupies the normal header's slot with the same chrome padding and
/// a content row exactly one chat-header hit target tall, so entering edit
/// mode never shifts the list beneath it. The overflow column opens the same
/// anchored popup the "+" and folder menus use (exteraless's ic_ab_other is
/// an ActionBarPopupWindowLayout, not a dialog) through a portal, which lets
/// the scrim cover the whole screen from any host.
class ChatSelectionHeader extends StatefulWidget {
  const ChatSelectionHeader({
    super.key,
    required this.count,
    required this.commands,
    required this.overflow,
    required this.onClose,
  });

  final int count;
  final List<ChatSelectionCommand> commands;
  final List<ChatSelectionCommand> overflow;
  final VoidCallback onClose;

  @override
  State<ChatSelectionHeader> createState() => ChatSelectionHeaderState();
}

class ChatSelectionHeaderState extends State<ChatSelectionHeader> {
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _overflowButtonKey = GlobalKey();
  bool _overflowOpen = false;

  /// The overflow button's rect in global coordinates, so a host can anchor a
  /// follow-up menu (the folder picker behind "Add to folder") to it.
  Rect? overflowButtonRect() {
    final box = _overflowButtonKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void initState() {
    super.initState();
    // The portal stays mounted for the whole edit-mode session: the popup's
    // reverse animation needs the subtree to survive `visible: false`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  void _closeOverflow() {
    if (!_overflowOpen) return;
    setState(() => _overflowOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hitTarget = AppMetric.chatHeaderHitTarget();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => AnchoredMenuOverlay(
        visible: _overflowOpen,
        top: MediaQuery.paddingOf(context).top + 48,
        onDismiss: _closeOverflow,
        child: _overflowMenu(context),
      ),
      child: Container(
        key: const ValueKey('chat-list-selection-header'),
        color: c.listHeaderTint,
        padding: headerChromePaddingOf(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md + AppSpacing.xxs,
          ),
          child: SizedBox(
            height: hitTarget,
            child: Row(
              children: [
                AppInteractiveSurface(
                  key: const ValueKey('chat-list-close-selection'),
                  semanticLabel: AppStringKeys.countryPickerCancel.l10n(
                    context,
                  ),
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: hitTarget,
                    height: hitTarget,
                    child: Center(
                      child: AppIcon(
                        HeroAppIcons.chevronLeft,
                        size: AppIconSize.nav,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    '${widget.count}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTextSize.bodyLarge,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                for (final command in widget.commands)
                  _directCommand(command, hitTarget),
                if (widget.overflow.isNotEmpty) _overflowButton(hitTarget),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _directCommand(ChatSelectionCommand command, double hitTarget) {
    final c = context.colors;
    return AppInteractiveSurface(
      key: ValueKey('chat-list-selection-${command.id}'),
      semanticLabel: command.label,
      onTap: command.onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: hitTarget,
        height: hitTarget,
        child: Center(
          child: AppIcon(
            command.icon,
            size: AppIconSize.toolbar,
            color: command.destructive ? AppTheme.tagRed : c.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _overflowButton(double hitTarget) {
    final c = context.colors;
    return AppInteractiveSurface(
      key: const ValueKey('chat-list-selection-overflow'),
      semanticLabel: AppStringKeys.chatMenu.l10n(context),
      onTap: () => setState(() => _overflowOpen = true),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: hitTarget,
        height: hitTarget,
        child: Center(
          child: AppIcon(
            HeroAppIcons.ellipsisVertical,
            size: AppIconSize.toolbar,
            color: c.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _overflowMenu(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const ValueKey('chat-list-selection-overflow-menu'),
      width: AppMetric.popupMenuWidth(),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.divider, width: 0.75),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final command in widget.overflow)
            AppInteractiveSurface(
              key: ValueKey('chat-list-selection-overflow-${command.id}'),
              semanticLabel: command.label,
              onTap: () {
                setState(() => _overflowOpen = false);
                command.onTap();
              },
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: SizedBox(
                height: AppMetric.popupMenuRowHeight(),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppMetric.popupMenuInset(),
                  ),
                  child: Row(
                    children: [
                      AppIcon(
                        command.icon,
                        size: AppMetric.popupMenuIconSlot(),
                        color: command.destructive
                            ? AppTheme.tagRed
                            : c.textPrimary,
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Text(
                          command.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppMetric.popupMenuTextSize(),
                            fontWeight: FontWeight.w500,
                            color: command.destructive
                                ? AppTheme.tagRed
                                : c.textPrimary,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
