part of 'message_bubble.dart';

extension _MessageBubbleMediaCards on _MessageBubbleState {
  // MARK: - Image

  int _cachePx(double logical) =>
      (logical * MediaQuery.devicePixelRatioOf(context)).ceil();

  bool _groupsMediaCaption(String? caption) =>
      caption != null && _theme.groupImageMessages;

  /// Width of a bubble that groups media with its caption. Like Telegram
  /// (Desktop `Photo::countCurrentSize`, the mobile clients' blurred side
  /// fill), the caption and attribution headers widen the bubble beyond a
  /// narrow or small preview, up to the media box, instead of being squeezed
  /// into the preview's width.
  double _groupedMediaWidth(double mediaWidth, String caption) {
    final maxWidth = _mediaMaxWidth();
    if (mediaWidth >= maxWidth) return mediaWidth;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout(maxWidth: maxWidth);
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final replacesOriginal = _translationReplacesOriginalFor(message);
    final entities = replacesOriginal
        ? message.translationEntities
        : _activeTextEntities;
    final spaced = _displaySpacing(
      replacesOriginal ? message.translationText ?? '' : caption,
      entities,
    );
    final bodyStyle = DefaultTextStyle.of(context).style.merge(
      AppTextStyle.messageBody(_incomingTextColor).copyWith(
        fontSize: _chatFontSize(AppTextSize.messageBody()),
        // Measure bold runs at their wider weight so they never wrap a word.
        fontWeight: spaced.entities.any((e) => e.type == 'textEntityTypeBold')
            ? FontWeight.bold
            : null,
      ),
    );
    // Caption padding is 6 on each side; headers are padded 10.
    var width = math.max(mediaWidth, measure(spaced.text, bodyStyle) + 12);
    final headerStyle = TextStyle(
      fontSize: AppTextSize.chatSecondary(AppTextSize.messageBody()),
      fontWeight: FontWeight.w500,
    );
    if (message.hasForwardAttribution) {
      final label = AppStrings.t(AppStringKeys.messageBubbleForwardedFrom, {
        'value1': message.forwardDisplayName,
      });
      // The 11 pt forward glyph and its 4 pt gap lead the label.
      width = math.max(width, measure(label, headerStyle) + 15 + 20);
    }
    if (message.hasViaBotAttribution) {
      final label = AppStrings.t(AppStringKeys.messageBubbleViaBot, {
        'value1': message.viaBotDisplayName,
      });
      width = math.max(width, measure(label, headerStyle) + 20);
    }
    return math.min(maxWidth, width.ceilToDouble());
  }

  /// Pads grouped video or animation [media] of [size] out to the grouped
  /// bubble width; separate media keeps its own width.
  ({Widget media, double width}) _groupedVideoFrame(
    Widget media,
    Size size,
    String? caption,
    BorderRadius borderRadius,
  ) {
    if (!_groupsMediaCaption(caption)) return (media: media, width: size.width);
    final width = _groupedMediaWidth(size.width, caption!);
    if (width <= size.width + 0.5) return (media: media, width: size.width);
    return (
      media: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.bubble.onPlayVideo?.call(message),
        child: SizedBox(
          width: width,
          height: size.height,
          child: _letterboxFrame(
            fillSource: message.image?.thumbnail ?? message.image,
            childSize: size,
            borderRadius: borderRadius,
            child: media,
          ),
        ),
      ),
      width: width,
    );
  }

  static bool _isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic');
  }

  String? _caption() {
    final text = _activeMessageText;
    return text.trim().isEmpty ? null : text;
  }

  Size _imageDisplaySize() {
    return _imagePreviewGeometry().frameSize;
  }

  /// A GIF's box: the same 320pt media budget as a photo, scaled by the one
  /// sticker/GIF size preference exteraless exposes. The lane caps the width so
  /// a larger setting grows tall GIFs instead of overflowing the bubble.
  Size _gifDisplaySize() {
    final lane = _mediaMaxWidth();
    final scale = _theme.stickerMediaScale;
    return telegramDesktopMediaPreviewGeometry(
      sourceWidth: message.imageWidth,
      sourceHeight: message.imageHeight,
      availableWidth: math.min(lane, lane * scale),
      maxHeight: telegramChatMediaPreviewMaxHeight * scale,
    ).frameSize;
  }

  /// A kept sticker renders as the sticker it was: `.tgs` lottie, `.webm`
  /// video or a static webp/png, at the sticker size, with no bubble surface.
  /// The mirror's snapshot is a local file, so the ghost shows the original
  /// sticker instead of a still image or a generic file row.
  Widget _keptStickerBubble(MessageHistoryEntry entry, bool outgoing) {
    final path = entry.mediaPath;
    final lower = path.toLowerCase();
    final box = _ghostStickerSize(entry);
    final ref = TdFileRef(
      id: _ghostFileId(path),
      localPath: path,
      fileName: entry.mediaFileName,
    );
    final Widget sticker;
    if (lower.endsWith('.tgs')) {
      sticker = AnimatedStickerView(
        key: ValueKey('ghostSticker-${message.id}'),
        file: ref,
      );
    } else if (lower.endsWith('.webm')) {
      final poster = entry.mediaPosterPath;
      sticker = VideoStickerView(
        key: ValueKey('ghostSticker-${message.id}'),
        file: ref,
        fallback: poster.isEmpty
            ? null
            : TdFileRef(id: _ghostFileId(poster), localPath: poster),
      );
    } else {
      sticker = Image.file(
        File(path),
        key: ValueKey('ghostSticker-${message.id}'),
        fit: BoxFit.contain,
        cacheWidth: _cachePx(box.width),
        cacheHeight: _cachePx(box.height),
        errorBuilder: (context, _, _) => Center(
          child: Text(
            localizedHistoryKindLabel(context, entry.kindKey),
            style: TextStyle(fontSize: 13, color: _colors.textSecondary),
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(openDownloadedFile(context, path)),
      onLongPress: _handleLongPress,
      onSecondaryTapUp: _handleSecondaryTapUp,
      child: SizedBox(width: box.width, height: box.height, child: sticker),
    );
  }

  /// A mirrored file has no TDLib id. Caches key on the id, so derive a stable
  /// negative one from the path — real ids are positive, so they never clash.
  int _ghostFileId(String path) => -((path.hashCode & 0x3fffffff) + 1);

  Size _ghostStickerSize(MessageHistoryEntry entry) {
    final maxSide = 120.0 * _theme.stickerMediaScale;
    final w = entry.mediaWidth, h = entry.mediaHeight;
    if (w <= 0 || h <= 0) return Size(maxSide, maxSide);
    final aspect = w / h;
    return aspect >= 1
        ? Size(maxSide, maxSide / aspect)
        : Size(maxSide * aspect, maxSide);
  }

  /// A kept copy whose media snapshot exists: a photo renders as the photo
  /// bubble (real aspect ratio, capped), every other kind as a file row on the
  /// message surface. Tapping opens the snapshot through the OS; long-press
  /// still opens the message menu (edit history, remove from mirror).
  Widget _keptMediaBubble(MessageHistoryEntry entry, bool outgoing) {
    if (entry.kindKey == 'historyKindSticker') {
      return _keptStickerBubble(entry, outgoing);
    }
    final kindLabel = localizedHistoryKindLabel(context, entry.kindKey);
    final caption = _caption();
    // Photos, static stickers and any kind with a poster paint as a still at
    // their real aspect; the rest is a compact file row on the bubble.
    final isPhoto = entry.kindKey == 'historyKindPhoto';
    final showsStill =
        isPhoto ||
        entry.mediaPosterPath.isNotEmpty ||
        (entry.kindKey == 'historyKindSticker' &&
            _isImagePath(entry.mediaPath));
    final media = MediaSnapshotView(
      path: entry.mediaPath,
      posterPath: entry.mediaPosterPath,
      kindKey: entry.kindKey,
      kindLabel: kindLabel,
      fileName: entry.mediaFileName,
      sourceWidth: entry.mediaWidth,
      sourceHeight: entry.mediaHeight,
      durationSeconds: entry.mediaDuration,
      maxWidth: showsStill ? _mediaMaxWidth() : null,
      maxHeight: showsStill ? telegramChatMediaPreviewMaxHeight : 240,
      onTap: () => unawaited(openDownloadedFile(context, entry.mediaPath)),
    );
    final interactive = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: _handleLongPress,
      onSecondaryTapUp: _handleSecondaryTapUp,
      child: media,
    );
    final width = showsStill
        ? telegramDesktopMediaPreviewGeometry(
            sourceWidth: entry.mediaWidth > 0 ? entry.mediaWidth : 4,
            sourceHeight: entry.mediaHeight > 0 ? entry.mediaHeight : 3,
            availableWidth: _mediaMaxWidth(),
            maxHeight: telegramChatMediaPreviewMaxHeight,
          ).frameSize.width
        : _bubbleMaxWidth();
    return _mediaWithCaption(
      media: showsStill
          ? interactive
          : Padding(
              padding: EdgeInsets.fromLTRB(
                10,
                10,
                10,
                caption == null ? 10 : 0,
              ),
              child: interactive,
            ),
      mediaWidth: width,
      caption: caption,
      outgoing: outgoing,
    );
  }

  MediaPreviewGeometry _imagePreviewGeometry() {
    return telegramDesktopMediaPreviewGeometry(
      sourceWidth: message.imageWidth,
      sourceHeight: message.imageHeight,
      availableWidth: _mediaMaxWidth(),
      maxHeight: telegramChatMediaPreviewMaxHeight,
    );
  }

  /// The height budget a rich block's media shares with ordinary chat media:
  /// the 320 pixel box, and never taller than a narrow pane is wide.
  double _richMediaMaxHeight(double maxWidth) =>
      math.min(maxWidth, telegramChatMediaPreviewMaxHeight);

  Size _fitSize({
    required int? width,
    required int? height,
    required double maxWidth,
    required double maxHeight,
    required Size fallback,
  }) {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return fallback;
    }
    final aspect = w / h;
    var dw = maxWidth;
    var dh = dw / aspect;
    if (dh > maxHeight) {
      dh = maxHeight;
      dw = dh * aspect;
    }
    return Size(dw, dh);
  }

  Size _stickerSize() {
    // 120pt at the stock setting; the sticker/GIF size preference scales it
    // (exteraless's stickerSize 4..20, default 14).
    final maxSide = 120.0 * _theme.stickerMediaScale;
    final w = message.imageWidth, h = message.imageHeight;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return Size(maxSide, maxSide);
    }
    final aspect = w / h;
    return aspect >= 1
        ? Size(maxSide, maxSide / aspect)
        : Size(maxSide * aspect, maxSide);
  }

  void _handleGroupedFileLongPress(ChatMessage source, GlobalKey itemKey) {
    if (_claimDesktopTouchLongPress(source, MessageActionSource.normal)) return;
    final box = itemKey.currentContext?.findRenderObject() as RenderBox?;
    final bounds = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    widget.bubble.onLongPress?.call(source, bounds, MessageActionSource.normal);
  }

  void _handleGroupedFileSecondaryTap(
    ChatMessage source,
    Offset globalPosition,
  ) {
    _markDesktopSecondaryHandled();
    widget.bubble.onLongPress?.call(
      source,
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      MessageActionSource.normal,
    );
  }

  bool _isGifDocument(MessageDocument document) =>
      document.ext.toLowerCase() == 'gif' ||
      document.fileName.toLowerCase().endsWith('.gif');

  String _fileCaptionText(ChatMessage source) {
    final text = source.text;
    return text.trim().isEmpty ? '' : text;
  }
}
