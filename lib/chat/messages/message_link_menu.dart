//
//  message_link_menu.dart
//
//  The menu a long press on a link inside a message opens, instead of the
//  message action menu. Port of exteraless's `ChatActivity.didLongPressLink`:
//  `ChatMessageCell.onLongPress` checks the pressed span first and, when it is
//  a link, shows a small anchored column (打开 / 复制 / 二维码) scrimmed over the
//  chat rather than the message's own menu.
//
//  Visual family: the touch dropdown of `message_action_menu.dart` — one
//  44pt row per option, `bodyLarge` labels, `AppIconSize.xl` glyphs,
//  `AppSpacing.xxl` row insets, hairline dividers and the same theme palette.
//

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../components/app_icons.dart';
import '../../components/app_press_ripple.dart';
import '../../theme/app_theme.dart';
import 'message_action_menu.dart';

/// What the pressed run points at. It decides the copy wording (and whether a
/// QR code makes sense at all).
enum MessageLinkKind { url, email, phone, mention, hashtag }

/// The option the reader picked. The bubble owns what each one does, the same
/// way it owns the tap route.
enum MessageLinkMenuAction { open, copy, showQr }

/// Everything the menu needs from the bubble that was long-pressed.
class MessageLinkHit {
  const MessageLinkHit({
    required this.kind,
    required this.anchor,
    this.qrValue,
  });

  final MessageLinkKind kind;

  /// Global rect of the pressed character; the column hangs off it.
  final Rect anchor;

  /// Non-null only for links a QR code can carry.
  final String? qrValue;
}

/// Opens exteraless's link menu for [hit]. Resolves with the picked option, or
/// null when the reader dismissed it.
Future<MessageLinkMenuAction?> showMessageLinkMenu(
  BuildContext context,
  MessageLinkHit hit,
) {
  return showGeneralDialog<MessageLinkMenuAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // exteraless dims the chat behind a ScrimOptions popup; the message stays
    // readable, the link column owns the touch.
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, _, _) => _MessageLinkMenuOverlay(hit: hit),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// A QR code for a link, the way exteraless's 分享二维码 option renders one.
Future<void> showMessageLinkQr(BuildContext context, String value) {
  return showDialog<void>(
    context: context,
    builder: (context) => _LinkQrDialog(value: value),
  );
}

class _LinkMenuEntry {
  const _LinkMenuEntry({
    required this.glyph,
    required this.label,
    required this.action,
  });

  final AppIconData glyph;
  final String label;
  final MessageLinkMenuAction action;
}

String _copyLabelFor(MessageLinkKind kind) => switch (kind) {
  MessageLinkKind.url => AppStringKeys.profileDetailCopyLink,
  MessageLinkKind.email => AppStringKeys.messageLinkCopyEmail,
  MessageLinkKind.phone => AppStringKeys.sharedContactCopyNumber,
  MessageLinkKind.mention => AppStringKeys.messageLinkCopyUsername,
  MessageLinkKind.hashtag => AppStringKeys.messageLinkCopyHashtag,
};

class _MessageLinkMenuOverlay extends StatelessWidget {
  const _MessageLinkMenuOverlay({required this.hit});

  final MessageLinkHit hit;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final entries = <_LinkMenuEntry>[
      const _LinkMenuEntry(
        glyph: HeroAppIcons.arrowTopRight,
        label: AppStringKeys.fileDetailOpen,
        action: MessageLinkMenuAction.open,
      ),
      _LinkMenuEntry(
        glyph: HeroAppIcons.documentDuplicate,
        label: _copyLabelFor(hit.kind),
        action: MessageLinkMenuAction.copy,
      ),
      if (hit.qrValue != null)
        const _LinkMenuEntry(
          glyph: HeroAppIcons.qrcode,
          label: AppStringKeys.messageLinkShareQr,
          action: MessageLinkMenuAction.showQr,
        ),
    ];
    final width = MessageActionMenu.mobileDropdownWidthFor(
      longestLabelWidth: _widestLabelWidth(context, entries),
      availableWidth: math.max(0.0, size.width - 20),
    );
    final double height =
        entries.length * MessageActionMenu.mobileDropdownRowHeight +
        MessageActionMenu.mobileDropdownVerticalInset * 2 +
        math.max(0, entries.length - 1).toDouble();
    // Under the pressed character when it fits, above it otherwise, then kept
    // inside the safe area — the same lift-not-overlap rule the message menu
    // follows.
    final anchor = hit.anchor;
    final left =
        (anchor.left - MessageActionMenu.mobileDropdownHorizontalPadding)
            .clamp(10.0, math.max(10.0, size.width - width - 10))
            .toDouble();
    double top = anchor.bottom + 6;
    if (top + height > size.height - safe.bottom - 10) {
      top = anchor.top - 6 - height;
    }
    top = top
        .clamp(
          safe.top + 10,
          math.max(safe.top + 10, size.height - safe.bottom - height - 10),
        )
        .toDouble();
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: _LinkMenuColumn(entries: entries),
        ),
      ],
    );
  }

  double _widestLabelWidth(BuildContext context, List<_LinkMenuEntry> entries) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var widest = 0.0;
    for (final entry in entries) {
      painter.text = TextSpan(
        text: AppStrings.t(entry.label),
        style: const TextStyle(
          fontSize: MessageActionMenu.mobileDropdownTextSize,
        ),
      );
      painter.layout();
      widest = math.max(widest, painter.width);
    }
    painter.dispose();
    return widest;
  }
}

class _LinkMenuColumn extends StatelessWidget {
  const _LinkMenuColumn({required this.entries});

  final List<_LinkMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final palette = MessageActionPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const ValueKey('message-link-menu'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: palette.divider, width: 0.75),
          boxShadow: [
            BoxShadow(
              color: palette.shadow,
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < entries.length; index++) ...[
              if (index > 0)
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  color: palette.divider,
                ),
              _LinkMenuRow(entry: entries[index], palette: palette),
            ],
          ],
        ),
      ),
    );
  }
}

class _LinkMenuRow extends StatelessWidget {
  const _LinkMenuRow({required this.entry, required this.palette});

  final _LinkMenuEntry entry;
  final MessageActionPalette palette;

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: MessageActionMenu.mobileDropdownRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MessageActionMenu.mobileDropdownHorizontalPadding,
        ),
        child: Row(
          children: [
            AppIcon(
              entry.glyph,
              size: MessageActionMenu.mobileDropdownIconSize,
              color: palette.foreground,
            ),
            const SizedBox(width: MessageActionMenu.mobileDropdownIconGap),
            Expanded(
              child: Text(
                AppStrings.t(entry.label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: MessageActionMenu.mobileDropdownTextSize,
                  color: palette.foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return GestureDetector(
      key: ValueKey('message-link-action-${entry.action.name}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(entry.action),
      child: AppPressRipple(color: palette.foreground, child: row),
    );
  }
}

class _LinkQrDialog extends StatelessWidget {
  const _LinkQrDialog({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: value,
              size: 224,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
            const SizedBox(height: 12),
            Text(
              value,
              key: const ValueKey('message-link-qr-value'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
