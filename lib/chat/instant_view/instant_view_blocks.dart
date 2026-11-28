//
//  instant_view_blocks.dart
//
//  The Instant View article body. [IvBlockView] maps one parsed page block to
//  a widget at the article's reading measure; media blocks live in
//  instant_view_media.dart. Blocks are laid out as a flat list — nested
//  containers (quotes, details, embedded posts, list items) recurse through
//  the same dispatcher with a slightly tighter context.
//

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/app_icons.dart';
import '../../components/photo_avatar.dart';
import '../../components/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';
import 'instant_view_links.dart';
import 'instant_view_media.dart';
import 'instant_view_models.dart';
import 'instant_view_text.dart';

/// Everything a block needs from the article page.
class IvRenderContext {
  const IvRenderContext({
    required this.context,
    required this.typography,
    required this.horizontalPadding,
    required this.anchorKeyFor,
    required this.onAnchor,
    required this.onOpenArticle,
    this.accountSlot,
    this.compact = false,
    this.applyGutter = true,
  });

  final BuildContext context;
  final IvTypography typography;
  final double horizontalPadding;
  final GlobalKey Function(String name) anchorKeyFor;
  final void Function(String anchor, String fallbackUrl) onAnchor;
  final void Function(String url) onOpenArticle;
  final int? accountSlot;
  final bool compact;

  /// True only for blocks laid out directly by the page: nested blocks live
  /// inside a container that already carries the reading gutter.
  final bool applyGutter;

  Color get textColor => typography.base.color ?? AppTheme.brand;
  Color get secondaryColor => typography.secondary;

  IvRenderContext copyWith({
    TextStyle? base,
    bool? compact,
    double? horizontalPadding,
    bool? applyGutter,
  }) => IvRenderContext(
    context: context,
    typography: typography.copyWith(base: base),
    horizontalPadding: horizontalPadding ?? this.horizontalPadding,
    anchorKeyFor: anchorKeyFor,
    onAnchor: onAnchor,
    onOpenArticle: onOpenArticle,
    accountSlot: accountSlot,
    compact: compact ?? this.compact,
    applyGutter: applyGutter ?? this.applyGutter,
  );

  /// Context for blocks nested inside a quote, details or embedded post.
  IvRenderContext get nested => copyWith(compact: true, applyGutter: false);
}

/// One block, including its vertical rhythm.
class IvBlockView extends StatelessWidget {
  const IvBlockView({super.key, required this.block, required this.ctx});

  final IvBlock block;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final view = _build(context);
    if (view == null) return const SizedBox.shrink();
    final spacing = _spacing(block);
    final gutter = ctx.applyGutter && block is! IvCoverBlock
        ? ctx.horizontalPadding
        : 0.0;
    final padding = spacing.add(EdgeInsets.symmetric(horizontal: gutter));
    if (padding == EdgeInsets.zero) return view;
    return Padding(padding: padding, child: view);
  }

  Widget? _build(BuildContext context) {
    switch (block) {
      case IvTitleBlock(:final title):
        return _Text(
          text: title,
          style: ctx.typography.base.copyWith(
            fontSize: 27,
            height: 1.22,
            fontWeight: FontWeight.w700,
            color: ctx.textColor,
          ),
          ctx: ctx,
        );
      case IvSubtitleBlock(:final subtitle):
        return _Text(
          text: subtitle,
          style: ctx.typography.base.copyWith(
            fontSize: 17,
            height: 1.35,
            color: ctx.secondaryColor,
          ),
          ctx: ctx,
        );
      case IvAuthorDateBlock(:final author, :final publishDate):
        final authorText = ivTextToPlain(author).trim();
        final date = formatIvDate(context, publishDate);
        return Wrap(
          spacing: 8,
          runSpacing: 3,
          children: [
            if (authorText.isNotEmpty)
              IvRichText(
                text: author,
                style: ctx.typography.copyWith(
                  base: ctx.typography.base.copyWith(
                    fontSize: 13,
                    color: ctx.secondaryColor,
                  ),
                ),
                onAnchor: ctx.onAnchor,
              ),
            if (date.isNotEmpty)
              Text(
                date,
                style: ctx.typography.base.copyWith(
                  fontSize: 13,
                  color: ctx.typography.base.color?.withValues(alpha: 0.62),
                ),
              ),
          ],
        );
      case IvHeaderBlock(:final header):
        return _Text(
          text: header,
          style: ctx.typography.base.copyWith(
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: ctx.textColor,
          ),
          ctx: ctx,
        );
      case IvSubheaderBlock(:final subheader):
        return _Text(
          text: subheader,
          style: ctx.typography.base.copyWith(
            fontSize: 18,
            height: 1.32,
            fontWeight: FontWeight.w600,
            color: ctx.textColor,
          ),
          ctx: ctx,
        );
      case IvSectionHeadingBlock(:final text, :final size):
        final fontSize = switch (size) {
          <= 1 => 22.0,
          2 => 20.0,
          3 => 18.0,
          4 => 17.0,
          5 => 16.0,
          _ => 15.0,
        };
        return _Text(
          text: text,
          style: ctx.typography.base.copyWith(
            fontSize: fontSize,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: ctx.textColor,
          ),
          ctx: ctx,
        );
      case IvKickerBlock(:final text):
        return _Text(
          text: text,
          style: ctx.typography.base.copyWith(
            fontSize: 13,
            height: 1.3,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: ctx.typography.accent,
          ),
          ctx: ctx,
        );
      case IvParagraphBlock(:final text):
        return _Text(text: text, style: ctx.typography.base, ctx: ctx);
      case IvPreformattedBlock(:final text, :final language):
        return _IvPreformatted(text: text, language: language, ctx: ctx);
      case IvFooterBlock(:final text):
        return _Text(
          text: text,
          style: ctx.typography.base.copyWith(
            fontSize: 13,
            color: ctx.secondaryColor,
          ),
          ctx: ctx,
        );
      case IvThinkingBlock(:final text):
        return _IvThinking(text: text, ctx: ctx);
      case IvDividerBlock():
        return Divider(
          height: 1,
          thickness: 1,
          color: ctx.typography.base.color?.withValues(alpha: 0.12),
        );
      case IvMathBlock(:final expression):
        return _IvMath(expression: expression, ctx: ctx);
      case IvAnchorBlock(:final name):
        return SizedBox(key: ctx.anchorKeyFor(name), height: 1);
      case IvListBlock(:final items):
        return _IvList(items: items, ctx: ctx);
      case IvBlockQuoteBlock(:final blocks, :final credit):
        return _IvQuote(blocks: blocks, credit: credit, ctx: ctx);
      case IvExpandableQuoteBlock(:final text, :final blocks, :final credit):
        return _IvExpandableQuote(
          text: text,
          blocks: blocks,
          credit: credit,
          ctx: ctx,
        );
      case IvPullQuoteBlock(:final text, :final credit):
        return _IvPullQuote(text: text, credit: credit, ctx: ctx);
      case IvAnimationBlock(
        :final animation,
        :final caption,
        :final hasSpoiler,
      ):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvVideoView(
            video: animation,
            ctx: ctx,
            hasSpoiler: hasSpoiler,
            loop: true,
          ),
        );
      case IvVideoBlock(:final video, :final caption, :final hasSpoiler):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvVideoView(video: video, ctx: ctx, hasSpoiler: hasSpoiler),
        );
      case IvPhotoBlock(:final photo, :final caption, :final hasSpoiler):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvPhotoView(photo: photo, ctx: ctx, hasSpoiler: hasSpoiler),
        );
      case IvAudioBlock(:final audio, :final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvAudioBlockView(audio: audio, ctx: ctx),
        );
      case IvVoiceNoteBlock(:final voiceNote, :final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvAudioBlockView(
            audio: IvAudio(file: voiceNote.file, duration: voiceNote.duration),
            ctx: ctx,
            voice: true,
          ),
        );
      case IvDocumentBlock(:final document, :final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvDocumentView(document: document, ctx: ctx),
        );
      case IvCoverBlock(:final cover):
        return _CoverView(cover: cover, ctx: ctx);
      case IvCollageBlock(:final blocks, :final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvCollageView(blocks: blocks, ctx: ctx),
        );
      case IvSlideshowBlock(:final blocks, :final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvSlideshowView(blocks: blocks, ctx: ctx),
        );
      case IvEmbeddedBlock(:final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvEmbeddedView(block: block as IvEmbeddedBlock, ctx: ctx),
        );
      case IvEmbeddedPostBlock(:final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvEmbeddedPostView(
            block: block as IvEmbeddedPostBlock,
            ctx: ctx,
          ),
        );
      case IvChatLinkBlock():
        return IvChatLinkView(block: block as IvChatLinkBlock, ctx: ctx);
      case IvTableBlock():
        return _IvTable(block: block as IvTableBlock, ctx: ctx);
      case IvDetailsBlock():
        return _IvDetails(block: block as IvDetailsBlock, ctx: ctx);
      case IvRelatedArticlesBlock(:final header, :final articles):
        return _IvRelatedArticles(header: header, articles: articles, ctx: ctx);
      case IvMapBlock(:final caption):
        return IvMediaBlock(
          ctx: ctx,
          caption: caption,
          child: IvMapView(block: block as IvMapBlock, ctx: ctx),
        );
      case IvButtonRowBlock(:final buttons, :final align):
        return _IvButtonRow(buttons: buttons, align: align, ctx: ctx);
      case IvUnsupportedBlock():
        return null;
    }
  }

  EdgeInsets _spacing(IvBlock block) {
    final tight = ctx.compact;
    double scale(double value) => tight ? value * 0.6 : value;
    return switch (block) {
      IvTitleBlock() => EdgeInsets.only(top: scale(6), bottom: scale(4)),
      IvSubtitleBlock() => EdgeInsets.only(bottom: scale(12)),
      IvAuthorDateBlock() => EdgeInsets.only(bottom: scale(14)),
      IvKickerBlock() => EdgeInsets.only(top: scale(10), bottom: scale(2)),
      IvHeaderBlock() => EdgeInsets.only(top: scale(18), bottom: scale(6)),
      IvSubheaderBlock() => EdgeInsets.only(top: scale(14), bottom: scale(4)),
      IvSectionHeadingBlock() => EdgeInsets.only(
        top: scale(16),
        bottom: scale(4),
      ),
      IvParagraphBlock() => EdgeInsets.only(bottom: scale(10)),
      IvPreformattedBlock() => EdgeInsets.only(
        top: scale(2),
        bottom: scale(12),
      ),
      IvFooterBlock() => EdgeInsets.only(top: scale(10), bottom: scale(4)),
      IvThinkingBlock() => EdgeInsets.only(bottom: scale(12)),
      IvDividerBlock() => EdgeInsets.symmetric(vertical: scale(14)),
      IvMathBlock() => EdgeInsets.only(bottom: scale(12)),
      IvListBlock() => EdgeInsets.only(bottom: scale(10)),
      IvBlockQuoteBlock() => EdgeInsets.only(bottom: scale(12)),
      IvExpandableQuoteBlock() => EdgeInsets.only(bottom: scale(12)),
      IvPullQuoteBlock() => EdgeInsets.symmetric(vertical: scale(12)),
      IvAnimationBlock() ||
      IvVideoBlock() ||
      IvPhotoBlock() ||
      IvAudioBlock() ||
      IvVoiceNoteBlock() ||
      IvDocumentBlock() ||
      IvCollageBlock() ||
      IvSlideshowBlock() ||
      IvEmbeddedBlock() ||
      IvEmbeddedPostBlock() ||
      IvMapBlock() => EdgeInsets.only(top: scale(4), bottom: scale(14)),
      IvCoverBlock() => EdgeInsets.only(bottom: scale(14)),
      IvChatLinkBlock() => EdgeInsets.only(bottom: scale(12)),
      IvTableBlock() => EdgeInsets.only(bottom: scale(12)),
      IvDetailsBlock() => EdgeInsets.only(bottom: scale(10)),
      IvRelatedArticlesBlock() => EdgeInsets.only(
        top: scale(8),
        bottom: scale(12),
      ),
      IvButtonRowBlock() => EdgeInsets.only(bottom: scale(12)),
      IvAnchorBlock() || IvUnsupportedBlock() => EdgeInsets.zero,
    };
  }
}

class _Text extends StatelessWidget {
  const _Text({required this.text, required this.style, required this.ctx});

  final IvText text;
  final TextStyle style;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) => IvRichText(
    text: text,
    style: ctx.typography.copyWith(base: style),
    onAnchor: ctx.onAnchor,
  );
}

class _CoverView extends StatelessWidget {
  const _CoverView({required this.cover, required this.ctx});

  final IvBlock cover;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    switch (cover) {
      case IvPhotoBlock(:final photo, :final hasSpoiler):
        return IvPhotoView(photo: photo, ctx: ctx, hasSpoiler: hasSpoiler);
      case IvVideoBlock(:final video, :final hasSpoiler):
        return IvVideoView(video: video, ctx: ctx, hasSpoiler: hasSpoiler);
      case IvAnimationBlock(:final animation, :final hasSpoiler):
        return IvVideoView(
          video: animation,
          ctx: ctx,
          hasSpoiler: hasSpoiler,
          loop: true,
        );
      default:
        return IvBlockView(block: cover, ctx: ctx);
    }
  }
}

class _IvPreformatted extends StatelessWidget {
  const _IvPreformatted({
    required this.text,
    required this.language,
    required this.ctx,
  });

  final IvText text;
  final String language;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final plain = ivTextToPlain(text);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ctx.typography.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.divider, width: AppMetric.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (language.trim().isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      language.trim(),
                      style: AppTextStyle.caption(c.textTertiary),
                    ),
                  ),
                  _IvCopyButton(text: plain),
                ],
              ),
            )
          else
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                child: _IvCopyButton(text: plain),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                plain,
                style: ctx.typography.fixed.copyWith(color: c.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IvCopyButton extends StatelessWidget {
  const _IvCopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        showToast(context, AppStringKeys.messageActionCopy);
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AppIcon(
          HeroAppIcons.documentDuplicate,
          size: 15,
          color: c.textTertiary,
        ),
      ),
    );
  }
}

class _IvMath extends StatelessWidget {
  const _IvMath({required this.expression, required this.ctx});

  final String expression;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: expression));
        if (!context.mounted) return;
        showToast(context, AppStringKeys.messageActionCopy);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ctx.typography.codeBackground,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          expression,
          textAlign: TextAlign.center,
          style: ctx.typography.fixed.copyWith(
            color: c.textPrimary,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

class _IvThinking extends StatelessWidget {
  const _IvThinking({required this.text, required this.ctx});

  final IvText text;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ctx.typography.codeBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(HeroAppIcons.lightbulb, size: 16, color: c.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: IvRichText(
              text: text,
              style: ctx.typography.copyWith(
                base: ctx.typography.base.copyWith(
                  fontSize: 14,
                  height: 1.45,
                  fontStyle: FontStyle.italic,
                  color: ctx.secondaryColor,
                ),
              ),
              onAnchor: ctx.onAnchor,
            ),
          ),
        ],
      ),
    );
  }
}

class _IvList extends StatelessWidget {
  const _IvList({required this.items, required this.ctx});

  final List<IvListItem> items;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _marker(context, items[i], i),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final block in items[i].blocks)
                        IvBlockView(block: block, ctx: ctx),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _marker(BuildContext context, IvListItem item, int index) {
    final c = context.colors;
    if (item.hasCheckbox) {
      return Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Icon(
          item.isChecked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18,
          color: item.isChecked ? AppTheme.brand : c.textTertiary,
        ),
      );
    }
    final ordered =
        item.label.trim().isNotEmpty ||
        (item.type.isNotEmpty && item.type != '*');
    final label = item.label.trim().isNotEmpty
        ? item.label.trim()
        : ordered
        ? '${item.value > 0 ? item.value : index + 1}${item.type == '1' || item.type.isEmpty ? '.' : ''}'
        : '•';
    return Text(
      label,
      style: ctx.typography.base.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: c.textSecondary,
      ),
    );
  }
}

class _IvQuote extends StatelessWidget {
  const _IvQuote({
    required this.blocks,
    required this.credit,
    required this.ctx,
  });

  final List<IvBlock> blocks;
  final IvText credit;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: AppTheme.brand, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final block in blocks)
            IvBlockView(block: block, ctx: ctx.copyWith(compact: true)),
          if (ivTextToPlain(credit).trim().isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: IvRichText(
                text: credit,
                style: ctx.typography.copyWith(
                  base: ctx.typography.base.copyWith(
                    fontSize: 12,
                    color: ctx.secondaryColor,
                  ),
                ),
                onAnchor: ctx.onAnchor,
              ),
            ),
        ],
      ),
    );
  }
}

class _IvExpandableQuote extends StatefulWidget {
  const _IvExpandableQuote({
    required this.text,
    required this.blocks,
    required this.credit,
    required this.ctx,
  });

  final IvText text;
  final List<IvBlock> blocks;
  final IvText credit;
  final IvRenderContext ctx;

  @override
  State<_IvExpandableQuote> createState() => _IvExpandableQuoteState();
}

class _IvExpandableQuoteState extends State<_IvExpandableQuote> {
  var _expanded = false;

  bool get _collapsible => ivTextToPlain(widget.text).trim().length > 280;

  @override
  Widget build(BuildContext context) {
    final collapsed = _collapsible && !_expanded;
    return Container(
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: AppTheme.brand, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ivTextToPlain(widget.text).trim().isNotEmpty)
            IvRichText(
              text: widget.text,
              style: widget.ctx.typography,
              maxLines: collapsed ? 6 : null,
              overflow: collapsed ? TextOverflow.fade : TextOverflow.clip,
              onAnchor: widget.ctx.onAnchor,
            )
          else
            for (final block in widget.blocks)
              IvBlockView(block: block, ctx: widget.ctx.nested),
          if (_collapsible)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  AppStrings.t(
                    _expanded
                        ? AppStringKeys.instantViewShowLess
                        : AppStringKeys.instantViewShowMore,
                  ),
                  style: AppTextStyle.caption(
                    AppTheme.brand,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (ivTextToPlain(widget.credit).trim().isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: IvRichText(
                text: widget.credit,
                style: widget.ctx.typography.copyWith(
                  base: widget.ctx.typography.base.copyWith(
                    fontSize: 12,
                    color: widget.ctx.secondaryColor,
                  ),
                ),
                onAnchor: widget.ctx.onAnchor,
              ),
            ),
        ],
      ),
    );
  }
}

class _IvPullQuote extends StatelessWidget {
  const _IvPullQuote({
    required this.text,
    required this.credit,
    required this.ctx,
  });

  final IvText text;
  final IvText credit;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IvRichText(
          text: text,
          textAlign: TextAlign.center,
          style: ctx.typography.copyWith(
            base: ctx.typography.base.copyWith(
              fontSize: 19,
              height: 1.4,
              fontStyle: FontStyle.italic,
              color: ctx.textColor,
            ),
          ),
          onAnchor: ctx.onAnchor,
        ),
        if (ivTextToPlain(credit).trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: IvRichText(
              text: credit,
              textAlign: TextAlign.center,
              style: ctx.typography.copyWith(
                base: ctx.typography.base.copyWith(
                  fontSize: 12,
                  color: ctx.secondaryColor,
                ),
              ),
              onAnchor: ctx.onAnchor,
            ),
          ),
      ],
    );
  }
}

class _IvButtonRow extends StatelessWidget {
  const _IvButtonRow({
    required this.buttons,
    required this.align,
    required this.ctx,
  });

  final List<IvButton> buttons;
  final IvAlign align;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: switch (align) {
        IvAlign.center => Alignment.center,
        IvAlign.right => Alignment.centerRight,
        IvAlign.left => Alignment.centerLeft,
      },
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final button in buttons)
            Material(
              color: button.isActionable
                  ? AppTheme.brand.withValues(alpha: 0.12)
                  : c.searchFill.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.control),
                onTap: button.isActionable
                    ? () => openIvButton(context, button.url!)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Text(
                    button.text,
                    style: AppTextStyle.callout(
                      button.isActionable ? AppTheme.brand : c.textSecondary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Button rows live outside the text renderer; route them through the same
/// link handler the article uses.
void openIvButton(BuildContext context, String url) {
  openIvUrl(context, url);
}

class _IvTable extends StatelessWidget {
  const _IvTable({required this.block, required this.ctx});

  final IvTableBlock block;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final rows = block.cells;
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows
        .map((row) => row.fold<int>(0, (sum, cell) => sum + cell.colspan))
        .fold<int>(1, math.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < rows.length; r++)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final cell in rows[r])
                        Expanded(
                          flex: cell.colspan,
                          child: _cell(context, cell, r),
                        ),
                      if (rows[r].fold<int>(
                            0,
                            (sum, cell) => sum + cell.colspan,
                          ) <
                          columns)
                        Expanded(
                          flex:
                              columns -
                              rows[r].fold<int>(
                                0,
                                (sum, cell) => sum + cell.colspan,
                              ),
                          child: const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (ivTextToPlain(block.caption).trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: IvRichText(
              text: block.caption,
              style: ctx.typography.copyWith(
                base: ctx.typography.base.copyWith(
                  fontSize: 12,
                  color: ctx.secondaryColor,
                ),
              ),
              onAnchor: ctx.onAnchor,
            ),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, IvTableCell cell, int rowIndex) {
    final c = context.colors;
    final striped = block.isStriped && rowIndex.isOdd;
    final header = cell.isHeader;
    final background = header
        ? c.searchFill.withValues(alpha: 0.9)
        : striped
        ? c.searchFill.withValues(alpha: 0.4)
        : Colors.transparent;
    final border = block.isBordered
        ? Border(
            right: BorderSide(color: c.divider, width: AppMetric.divider),
            bottom: BorderSide(color: c.divider, width: AppMetric.divider),
          )
        : null;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: block.isCompact ? 5 : 9,
        vertical: block.isCompact ? 3 : 7,
      ),
      decoration: BoxDecoration(color: background, border: border),
      alignment: switch (cell.align) {
        IvAlign.center => Alignment.center,
        IvAlign.right => Alignment.centerRight,
        IvAlign.left => Alignment.centerLeft,
      },
      child: IvRichText(
        text: cell.text,
        textAlign: switch (cell.align) {
          IvAlign.center => TextAlign.center,
          IvAlign.right => TextAlign.end,
          IvAlign.left => TextAlign.start,
        },
        style: ctx.typography.copyWith(
          base: ctx.typography.base.copyWith(
            fontSize: block.isCompact ? 13 : 14,
            height: 1.3,
            fontWeight: header ? FontWeight.w700 : FontWeight.w400,
            color: ctx.textColor,
          ),
        ),
        onAnchor: ctx.onAnchor,
      ),
    );
  }
}

class _IvDetails extends StatefulWidget {
  const _IvDetails({required this.block, required this.ctx});

  final IvDetailsBlock block;
  final IvRenderContext ctx;

  @override
  State<_IvDetails> createState() => _IvDetailsState();
}

class _IvDetailsState extends State<_IvDetails> {
  late var _open = widget.block.isOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.searchFill.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Expanded(
                  child: IvRichText(
                    text: widget.block.header,
                    style: widget.ctx.typography.copyWith(
                      base: widget.ctx.typography.base.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: widget.ctx.textColor,
                      ),
                    ),
                    onAnchor: widget.ctx.onAnchor,
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: AppMotion.swap,
                  child: AppIcon(
                    HeroAppIcons.chevronDown,
                    size: 16,
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final block in widget.block.blocks)
                    IvBlockView(block: block, ctx: widget.ctx.nested),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _IvRelatedArticles extends StatelessWidget {
  const _IvRelatedArticles({
    required this.header,
    required this.articles,
    required this.ctx,
  });

  final IvText header;
  final List<IvRelatedArticle> articles;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (articles.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ivTextToPlain(header).trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IvRichText(
              text: header,
              style: ctx.typography.copyWith(
                base: ctx.typography.base.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: ctx.textColor,
                ),
              ),
              onAnchor: ctx.onAnchor,
            ),
          ),
        for (final article in articles)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: c.searchFill.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: article.url.isEmpty
                    ? null
                    : () => ctx.onOpenArticle(article.url),
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (article.photo?.image != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox.square(
                            dimension: 64,
                            child: TDImage(
                              photo: article.photo!.image,
                              cornerRadius: 0,
                            ),
                          ),
                        ),
                      if (article.photo?.image != null)
                        const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (article.title.trim().isNotEmpty)
                              Text(
                                article.title.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.3,
                                  fontWeight: FontWeight.w600,
                                  color: ctx.textColor,
                                ),
                              ),
                            if (article.description.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  article.description.trim(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: ctx.secondaryColor,
                                  ),
                                ),
                              ),
                            if (article.author.trim().isNotEmpty ||
                                article.publishDate > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  [
                                    if (article.author.trim().isNotEmpty)
                                      article.author.trim(),
                                    if (article.publishDate > 0)
                                      formatIvDate(
                                        context,
                                        article.publishDate,
                                      ),
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: c.textTertiary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
