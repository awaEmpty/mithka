//
//  message_history_entry_view.dart
//
//  One kept message of the local mirror, rendered like a chat bubble: the
//  text (or media snapshot), the sender line, and the edit trail. Deleted
//  entries get the translucent ghost styling. Long-press
//  copies the kept text. Part of the Telegram API Terms §1.4 mirror that
//  exists only in opted-in self-builds.
//

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/toast.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'message_history_labels.dart';
import 'message_history_models.dart';
import 'message_history_settings.dart';
import 'message_media_snapshot.dart';
import 'message_media_snapshot_view.dart';

export 'message_history_labels.dart';
export 'message_media_snapshot_view.dart';

/// Renders one [MessageHistoryEntry] as a standalone bubble-shaped card.
class MessageHistoryEntryView extends StatelessWidget {
  const MessageHistoryEntryView({
    super.key,
    required this.entry,
    required this.chatTitle,
    this.showChatTitle = true,
    this.senderName,
    this.mediaDir,
    this.onOpenMedia,
    this.trailing,
  });

  final MessageHistoryEntry entry;

  /// Chat display title (already resolved by the caller).
  final String chatTitle;

  /// Whether the chat header line is rendered (hidden inside a chat-scoped
  /// list where every row shares it).
  final bool showChatTitle;

  /// Resolved sender display name, when known.
  final String? senderName;

  /// Directory holding the media snapshots; supplied by the caller when
  /// previews should resolve snapshot paths (the viewer owns the snapshotter
  /// wiring). Null keeps media-only rows on their kind label.
  final MessageMediaSnapshotter? mediaDir;

  /// Opens the snapshot file in the system viewer (photos/videos/audio —
  /// whatever the OS can play); a kind label stays the fallback when the
  /// file is gone.
  final void Function(String path)? onOpenMedia;

  /// Optional trailing widget in the header line (e.g. a delete button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final entry = this.entry;
    final c = context.colors;
    final deleted =
        entry.state == MessageHistoryState.deleted || !entry.hasLiveChat;
    final senderLine = senderName ?? '';
    final kindLabel = entry.kindKey.isEmpty
        ? ''
        : _localizedKindLabel(context, entry.kindKey);
    return AppInteractiveSurface(
      onLongPress: () => _copyEntry(context, entry),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.divider, width: 0.5),
        ),
        foregroundDecoration: deleted
            ? BoxDecoration(
                color: c.groupedBackground.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
              )
            : null,
        child: Opacity(
          opacity: deleted ? 0.55 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (entry.state == MessageHistoryState.deleted) ...[
                    const _StatusBadge(deleted: true),
                    if (entry.isEdited) const SizedBox(width: 4),
                  ],
                  if (entry.isEdited) const _StatusBadge(deleted: false),
                  if (entry.state == MessageHistoryState.deleted ||
                      entry.isEdited)
                    const SizedBox(width: 7),
                  if (showChatTitle) ...[
                    Expanded(
                      child: Text(
                        chatTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.footnote(c.textSecondary),
                      ),
                    ),
                  ] else if (senderLine.isNotEmpty) ...[
                    Expanded(
                      child: Text(
                        senderLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.footnote(c.textPrimary),
                      ),
                    ),
                  ] else ...[
                    const Expanded(child: SizedBox.shrink()),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    _formatDateTime(entry.date),
                    style: AppTextStyle.footnote(c.textTertiary),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
              const SizedBox(height: 6),
              _content(context, entry, kindLabel),
              if (entry.events.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final event in entry.events)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      AppStrings.t(AppStringKeys.historyEditEvent, {
                        'value1': _formatDateTime(event.at),
                        'value2': event.newText.isEmpty
                            ? AppStrings.t(AppStringKeys.historyKindUnknown)
                            : event.newText,
                      }),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote(c.textTertiary),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    MessageHistoryEntry entry,
    String kindLabel,
  ) {
    final c = context.colors;
    final text = entry.text.trim();
    final media = _snapshotPath(entry);
    if (media == null) {
      if (text.isNotEmpty) {
        return Text(text, style: AppTextStyle.body(c.textPrimary));
      }
      return Text(kindLabel, style: AppTextStyle.body(c.textSecondary));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MediaSnapshotView(
            path: media,
            posterPath: entry.mediaPosterPath,
            kindKey: entry.kindKey,
            kindLabel: kindLabel,
            fileName: entry.mediaFileName,
            sourceWidth: entry.mediaWidth,
            sourceHeight: entry.mediaHeight,
            durationSeconds: entry.mediaDuration,
            maxHeight: 220,
            onTap: onOpenMedia == null ? null : () => onOpenMedia!(media),
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(text, style: AppTextStyle.body(c.textPrimary)),
          ],
        ],
      ),
    );
  }

  /// The snapshot path recorded on the entry, validated against the current
  /// snapshot directory so a stale path (file wiped, directory moved) renders
  /// the kind label instead of a broken preview.
  String? _snapshotPath(MessageHistoryEntry entry) {
    if (entry.mediaPath.isEmpty) return null;
    final directory = mediaDir?.dir?.path;
    if (directory == null) return null;
    if (!entry.mediaPath.startsWith('$directory/')) return null;
    return entry.mediaPath;
  }

  /// Localized kind name for a stored kind suffix; unknown kinds keep the
  /// generic label instead of leaking the raw key.
  static String _localizedKindLabel(BuildContext context, String suffix) =>
      localizedHistoryKindLabel(context, suffix);

  Future<void> _copyEntry(BuildContext context, MessageHistoryEntry entry) {
    final text = entry.text.trim();
    if (text.isEmpty) return Future<void>.value();
    return Clipboard.setData(ClipboardData(text: text)).then((_) {
      if (context.mounted) {
        showToast(context, AppStringKeys.topicPostContentCopied.l10n(context));
      }
    });
  }
}

String _formatDateTime(int unixSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Compact "Deleted" / "Edited" pill for a kept copy's header. The deleted
/// badge follows the same [GhostBadgeStyle] as the in-chat ghost chip, so the
/// viewer and the transcript never disagree about how a deletion is marked.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.deleted});

  final bool deleted;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = deleted
        ? MessageHistorySettings.shared.badgeStyle
        : GhostBadgeStyle.both;
    final showIcon = style != GhostBadgeStyle.text;
    final showText = style != GhostBadgeStyle.icon;
    final color = deleted ? c.textTertiary : c.textSecondary;
    final label = deleted
        ? AppStringKeys.historyDeletedLabel.l10n(context)
        : AppStringKeys.historyEditedLabel.l10n(context);
    return Container(
      key: ValueKey(
        deleted ? 'history-status-deleted' : 'history-status-edited',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: c.groupedBackground,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon)
            AppIcon(
              deleted ? HeroAppIcons.trash : HeroAppIcons.penToSquare,
              size: 11,
              color: color,
            ),
          if (showIcon && showText) const SizedBox(width: 3),
          if (showText)
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote(
                color,
              ).copyWith(fontSize: 11, height: 1.1),
            ),
        ],
      ),
    );
  }
}
