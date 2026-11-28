//
//  instant_view_text.dart
//
//  Renders TDLib `RichText` runs as Flutter spans: styles, links, anchors,
//  custom emoji, inline math and spoilers. [IvRichText] owns the tap
//  recognizers (and the spoiler reveal state) so article blocks stay
//  stateless.
//

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../components/photo_avatar.dart';
import '../../theme/app_theme.dart';
import '../stickers/custom_emoji.dart';
import 'instant_view_links.dart';
import 'instant_view_models.dart';

/// Typography shared by every run of one article surface.
class IvTypography {
  const IvTypography({
    required this.base,
    required this.accent,
    required this.secondary,
    required this.codeBackground,
    this.highlight = '',
  });

  final TextStyle base;
  final Color accent;
  final Color secondary;
  final Color codeBackground;

  /// In-article search query; matching runs get a highlight background.
  final String highlight;

  TextStyle get fixed => base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
    fontSize: (base.fontSize ?? 16) * 0.9,
    backgroundColor: codeBackground,
  );

  IvTypography copyWith({TextStyle? base, String? highlight}) => IvTypography(
    base: base ?? this.base,
    accent: accent,
    secondary: secondary,
    codeBackground: codeBackground,
    highlight: highlight ?? this.highlight,
  );
}

/// One rich-text paragraph. Rebuilds dispose their previous recognizers.
class IvRichText extends StatefulWidget {
  const IvRichText({
    super.key,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.start,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.onAnchor,
  });

  final IvText text;
  final IvTypography style;
  final TextAlign textAlign;
  final int? maxLines;
  final TextOverflow overflow;

  /// Called for `richTextAnchorLink` / `richTextReferenceLink` runs. The
  /// article scrolls to [anchor] when it exists, otherwise opens
  /// [fallbackUrl].
  final void Function(String anchor, String fallbackUrl)? onAnchor;

  @override
  State<IvRichText> createState() => _IvRichTextState();
}

class _IvRichTextState extends State<IvRichText> {
  final Set<String> _revealedSpoilers = {};
  List<TapGestureRecognizer> _recognizers = const [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers = const [];
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final recognizers = <TapGestureRecognizer>[];
    final builder = IvSpanBuilder(
      context: context,
      style: widget.style,
      revealedSpoilers: _revealedSpoilers,
      onRevealSpoiler: (key) {
        if (!mounted) return;
        setState(() => _revealedSpoilers.add(key));
      },
      onAnchor: widget.onAnchor,
      recognizers: recognizers,
    );
    final spans = builder.build(widget.text);
    _recognizers = recognizers;
    return Text.rich(
      TextSpan(children: spans),
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      style: widget.style.base,
    );
  }
}

/// Builds spans without the spoiler state machine, for one-shot labels
/// (menu rows, accessibility strings, template previews).
List<InlineSpan> buildIvSpans({
  required BuildContext context,
  required IvText text,
  required IvTypography style,
}) {
  final builder = IvSpanBuilder(
    context: context,
    style: style,
    revealedSpoilers: const {},
    onRevealSpoiler: (_) {},
    onAnchor: null,
    recognizers: <TapGestureRecognizer>[],
  );
  return builder.build(text);
}

class IvSpanBuilder {
  IvSpanBuilder({
    required this.context,
    required this.style,
    required this.revealedSpoilers,
    required this.onRevealSpoiler,
    required this.onAnchor,
    required this.recognizers,
  });

  final BuildContext context;
  final IvTypography style;
  final Set<String> revealedSpoilers;
  final void Function(String key) onRevealSpoiler;
  final void Function(String anchor, String fallbackUrl)? onAnchor;
  final List<TapGestureRecognizer> recognizers;
  int _spoilerSeq = 0;

  List<InlineSpan> build(IvText text) {
    final out = <InlineSpan>[];
    _walk(text, style.base, null, null, out);
    return out;
  }

  void _walk(
    IvText node,
    TextStyle current,
    TapGestureRecognizer? spoiler,
    TapGestureRecognizer? link,
    List<InlineSpan> out,
  ) {
    switch (node) {
      case IvTextPlain(:final text):
        if (text.isEmpty) return;
        if (spoiler == null) {
          _emitPlain(text, current, link, out);
          return;
        }
        out.add(
          TextSpan(
            text: text,
            style: _hiddenStyle(current),
            recognizer: spoiler,
          ),
        );
      case IvTextConcat(:final children):
        for (final child in children) {
          _walk(child, current, spoiler, link, out);
        }
      case IvTextStyled(style: final textStyle, :final child):
        if (textStyle == IvTextStyle.spoiler) {
          _buildSpoiler(child, current, link, out);
        } else {
          _walk(child, _applyStyle(current, textStyle), spoiler, link, out);
        }
      case IvTextLink():
        final target = spoiler != null ? null : _linkRecognizer(node);
        _walk(
          node.child,
          current.copyWith(
            color: style.accent,
            decoration: TextDecoration.none,
          ),
          spoiler,
          target ?? link,
          out,
        );
      case IvTextCustomEmoji(:final id, :final alternativeText):
        if (spoiler != null) {
          out.add(
            TextSpan(
              text: alternativeText,
              style: _hiddenStyle(current),
              recognizer: spoiler,
            ),
          );
          return;
        }
        out.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SelectableCustomEmojiView(
              id: id,
              fallbackText: alternativeText,
              size: _customEmojiSize(current),
              color: current.color,
            ),
          ),
        );
      case IvTextIcon(:final file, :final width, :final height):
        final size = _iconSize(current, width, height);
        out.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Opacity(
              opacity: spoiler == null ? 1 : 0,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: TDImage(
                  photo: file,
                  cornerRadius: 0,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );
      case IvTextMath(:final expression):
        out.add(
          TextSpan(
            text: expression,
            style: current.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
              color: spoiler == null ? style.accent : Colors.transparent,
              backgroundColor: style.codeBackground,
            ),
            recognizer: spoiler ?? link,
          ),
        );
      case IvTextDate(:final child):
        _walk(child, current, spoiler, link, out);
      case IvTextButton(:final button):
        if (!button.isActionable || spoiler != null) {
          _walk(IvTextPlain(button.text), current, spoiler, link, out);
          return;
        }
        out.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _IvInlineButton(
              label: button.text,
              onTap: () => openIvUrl(context, button.url!),
            ),
          ),
        );
      case IvTextDiff(:final text, :final oldText):
        out.add(
          TextSpan(
            children: [
              TextSpan(
                text: ivTextToPlain(oldText),
                style: current.copyWith(
                  decoration: TextDecoration.lineThrough,
                  color: style.secondary,
                ),
              ),
              const TextSpan(text: ' '),
            ],
          ),
        );
        _walk(text, current, spoiler, link, out);
      case IvTextReference(:final name, :final text):
        _walk(text, current, spoiler, link, out);
        if (name.isNotEmpty) {
          out.add(
            TextSpan(
              text: name,
              style: current.copyWith(
                fontSize: (current.fontSize ?? 16) * 0.7,
                color: style.accent,
              ),
            ),
          );
        }
      case IvTextAnchor():
        // Inline anchor markers carry no text.
        return;
      case IvTextUnknown(:final text):
        if (text.isNotEmpty) {
          _walk(IvTextPlain(text), current, spoiler, link, out);
        }
    }
  }

  void _emitPlain(
    String text,
    TextStyle current,
    TapGestureRecognizer? recognizer,
    List<InlineSpan> out,
  ) {
    final query = style.highlight.trim();
    if (query.isEmpty) {
      out.add(TextSpan(text: text, style: current, recognizer: recognizer));
      return;
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var start = 0;
    while (start < text.length) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index < 0) {
        out.add(
          TextSpan(
            text: text.substring(start),
            style: current,
            recognizer: recognizer,
          ),
        );
        return;
      }
      if (index > start) {
        out.add(
          TextSpan(
            text: text.substring(start, index),
            style: current,
            recognizer: recognizer,
          ),
        );
      }
      out.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: current.copyWith(
            backgroundColor: style.accent.withValues(alpha: 0.30),
          ),
          recognizer: recognizer,
        ),
      );
      start = index + query.length;
    }
  }

  void _buildSpoiler(
    IvText child,
    TextStyle current,
    TapGestureRecognizer? link,
    List<InlineSpan> out,
  ) {
    final key = 'spoiler:${_spoilerSeq++}';
    if (revealedSpoilers.contains(key)) {
      _walk(child, current, null, link, out);
      return;
    }
    final recognizer = TapGestureRecognizer()
      ..onTap = () => onRevealSpoiler(key);
    recognizers.add(recognizer);
    _walk(child, current, recognizer, null, out);
  }

  TextStyle _applyStyle(TextStyle current, IvTextStyle styleFlag) {
    switch (styleFlag) {
      case IvTextStyle.bold:
        return current.copyWith(fontWeight: FontWeight.w700);
      case IvTextStyle.italic:
        return current.copyWith(fontStyle: FontStyle.italic);
      case IvTextStyle.underline:
        return current.copyWith(decoration: TextDecoration.underline);
      case IvTextStyle.strikethrough:
        return current.copyWith(decoration: TextDecoration.lineThrough);
      case IvTextStyle.spoiler:
        return current;
      case IvTextStyle.subscript:
      case IvTextStyle.superscript:
        return current.copyWith(fontSize: (current.fontSize ?? 16) * 0.75);
      case IvTextStyle.marked:
        return current.copyWith(backgroundColor: style.codeBackground);
      case IvTextStyle.fixed:
        return current.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
          fontSize: (current.fontSize ?? 16) * 0.9,
          backgroundColor: style.codeBackground,
        );
    }
  }

  TextStyle _hiddenStyle(TextStyle current) => current.copyWith(
    color: Colors.transparent,
    decoration: TextDecoration.none,
    backgroundColor: style.accent.withValues(alpha: 0.28),
  );

  TapGestureRecognizer? _linkRecognizer(IvTextLink link) {
    switch (link.kind) {
      case IvLinkKind.anchorLink:
      case IvLinkKind.referenceLink:
        final anchor = link.value;
        final fallback = link.fallbackUrl;
        final handler = onAnchor;
        if (handler == null) return null;
        return _recognizer(() => handler(anchor, fallback));
      case IvLinkKind.url:
        return _recognizer(() => openIvUrl(context, link.value));
      case IvLinkKind.email:
        return _recognizer(() => openIvUrl(context, 'mailto:${link.value}'));
      case IvLinkKind.phone:
        return _recognizer(() => openIvUrl(context, 'tel:${link.value}'));
      case IvLinkKind.mention:
        return _recognizer(
          () => openIvUrl(context, 'https://t.me/${link.value}'),
        );
      case IvLinkKind.hashtag:
      case IvLinkKind.cashtag:
        final tag = link.value.replaceFirst(RegExp(r'^[#$]'), '');
        return _recognizer(
          () =>
              openIvUrl(context, 'https://t.me/s/${Uri.encodeComponent(tag)}'),
        );
      case IvLinkKind.botCommand:
        return _recognizer(
          () => openIvUrl(
            context,
            'https://t.me/${link.value.replaceFirst('/', '')}',
          ),
        );
      case IvLinkKind.bankCard:
        return _recognizer(
          () => openIvUrl(context, 'https://t.me/${link.value}'),
        );
      case IvLinkKind.tonAddress:
        return _recognizer(
          () => openIvUrl(context, 'https://tonviewer.com/${link.value}'),
        );
      case IvLinkKind.mentionName:
        return _recognizer(() => openIvUser(context, link.userId));
      case IvLinkKind.anchor:
        return null;
    }
  }

  TapGestureRecognizer _recognizer(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    recognizers.add(recognizer);
    return recognizer;
  }

  double _customEmojiSize(TextStyle current) {
    final size = current.fontSize ?? style.base.fontSize ?? 16;
    return (size * 1.15).clamp(16, 40).toDouble();
  }

  Size _iconSize(TextStyle current, int width, int height) {
    final maxSide = ((current.fontSize ?? 16) * 1.3).clamp(14, 48).toDouble();
    if (width <= 0 || height <= 0) return Size(maxSide, maxSide);
    final scale = maxSide / (height > width ? height : width);
    return Size(
      (width * scale).clamp(8, maxSide).toDouble(),
      (height * scale).clamp(8, maxSide).toDouble(),
    );
  }
}

class _IvInlineButton extends StatelessWidget {
  const _IvInlineButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: AppTheme.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              label,
              style: AppTextStyle.caption(
                c.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
