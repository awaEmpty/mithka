//
//  message_media_snapshot_view.dart
//
//  One media snapshot of the kept-message mirror, rendered the same way in
//  the history viewer and in the in-chat ghost bubble: photos inline at their
//  real aspect ratio (capped), video and animated-sticker previews from the
//  poster frame kept next to the file, and every other kind as a file row.
//  The file is the snapshot copy, so a deleted message shows its actual media
//  instead of a bare "Photo" label.
//

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import '../chat/messages/media_preview_geometry.dart';
import '../components/app_icons.dart';
import '../media/media_metadata.dart';
import '../theme/app_theme.dart';

/// Renders a mirrored media file. [onTap] opens it externally; a missing file
/// falls back to [kindLabel] — never to a broken preview.
class MediaSnapshotView extends StatefulWidget {
  const MediaSnapshotView({
    super.key,
    required this.path,
    required this.kindKey,
    required this.kindLabel,
    this.posterPath = '',
    this.fileName = '',
    this.sourceWidth = 0,
    this.sourceHeight = 0,
    this.durationSeconds = 0,
    this.maxWidth,
    this.maxHeight = 240,
    this.cornerRadius = 10,
    this.onTap,
  });

  /// The original media file (photo/video/document/...).
  final String path;

  /// Thumbnail kept next to [path]; the only still a video or an animated
  /// sticker can be previewed from.
  final String posterPath;

  final String kindKey;
  final String kindLabel;
  final String fileName;

  /// Pixel size of the file, 0 when the mirror did not record one. Photos are
  /// laid out from it; an unknown size falls back to 4:3.
  final int sourceWidth;
  final int sourceHeight;

  final int durationSeconds;

  /// Layout cap; null takes the incoming constraint (the viewer card's width).
  final double? maxWidth;
  final double maxHeight;
  final double cornerRadius;

  final VoidCallback? onTap;

  @override
  State<MediaSnapshotView> createState() => _MediaSnapshotViewState();
}

class _MediaSnapshotViewState extends State<MediaSnapshotView> {
  bool? _exists;

  bool get _isPhoto => widget.kindKey == 'historyKindPhoto';

  bool get _isSticker => widget.kindKey == 'historyKindSticker';

  bool get _isVideoLike =>
      widget.kindKey == 'historyKindVideo' ||
      widget.kindKey == 'historyKindVideoNote' ||
      widget.kindKey == 'historyKindAnimation';

  /// The file actually painted, or '' when this kind has no still preview and
  /// the view falls back to the file row.
  String get _imagePath {
    if (_isPhoto) return widget.path;
    // A static sticker IS the image (webp/png); animated and video stickers
    // are `.tgs`/`.webm`, which Image.file cannot decode.
    if (_isSticker && _looksLikeImage(widget.path)) return widget.path;
    if (widget.posterPath.isNotEmpty && (_isVideoLike || _isSticker)) {
      return widget.posterPath;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(MediaSnapshotView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.posterPath != widget.posterPath) {
      _check();
    }
  }

  void _check() {
    final path = _imagePath.isNotEmpty ? _imagePath : widget.path;
    if (path.isEmpty) {
      _exists = false;
      return;
    }
    // Plain test() bodies may await real IO; widget tests drive this widget
    // through runAsync-free pumps, so resolve asynchronously and rebuild.
    File(path).exists().then((exists) {
      if (mounted) setState(() => _exists = exists);
    });
  }

  @override
  Widget build(BuildContext context) {
    final imagePath = _imagePath;
    Widget body;
    if (imagePath.isEmpty) {
      body = _fileRow(context);
    } else if (_exists == false) {
      body = _fallbackLabel(context);
    } else {
      body = _image(context, imagePath);
    }
    final onTap = widget.onTap;
    if (onTap == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: body,
    );
  }

  Widget _image(BuildContext context, String path) {
    final sourceWidth = widget.sourceWidth > 0 ? widget.sourceWidth : 4;
    final sourceHeight = widget.sourceHeight > 0 ? widget.sourceHeight : 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = widget.maxWidth;
        final available =
            maxWidth ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : telegramDesktopMediaPreviewMaxSide);
        final geometry = telegramDesktopMediaPreviewGeometry(
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          availableWidth: math.max(1, available),
          maxHeight: widget.maxHeight,
        );
        // Decode at the painted size: a kept full-size photo can be tens of
        // megapixels, and the bubble only ever shows a few hundred pixels.
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final cacheWidth = (geometry.frameSize.width * dpr).round().clamp(
          1,
          2048,
        );
        final frame = SizedBox(
          width: geometry.frameSize.width,
          height: geometry.frameSize.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.cornerRadius),
            child: Image.file(
              File(path),
              key: ValueKey('history-media-$path'),
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
              errorBuilder: (_, _, _) => _fallbackLabel(context),
            ),
          ),
        );
        if (!_isVideoLike && widget.kindKey != 'historyKindAnimation') {
          return frame;
        }
        return Stack(
          alignment: Alignment.center,
          children: [
            frame,
            _badge(
              widget.kindKey == 'historyKindAnimation'
                  ? HeroAppIcons.gif
                  : HeroAppIcons.play,
            ),
          ],
        );
      },
    );
  }

  /// Centered pill over a preview: play for video, GIF for animations.
  Widget _badge(AppIconData icon) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x40FFFFFF)),
      ),
      child: AppIcon(icon, size: 16, color: const Color(0xFFFFFFFF)),
    );
  }

  Widget _fileRow(BuildContext context) {
    final c = context.colors;
    final title = widget.fileName.trim().isNotEmpty
        ? widget.fileName.trim()
        : widget.kindLabel;
    final duration = widget.durationSeconds > 0
        ? formatMediaDuration(widget.durationSeconds)
        : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.groupedBackground,
            borderRadius: BorderRadius.circular(9),
          ),
          child: AppIcon(
            _kindIcon(widget.kindKey),
            size: 17,
            color: c.textSecondary,
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.body(c.textPrimary),
              ),
              if (duration.isNotEmpty)
                Text(
                  duration,
                  maxLines: 1,
                  style: AppTextStyle.footnote(c.textTertiary),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fallbackLabel(BuildContext context) => Text(
    widget.kindLabel,
    style: AppTextStyle.body(context.colors.textSecondary),
  );

  static bool _looksLikeImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic');
  }

  static AppIconData _kindIcon(String kindKey) => switch (kindKey) {
    'historyKindVideo' ||
    'historyKindVideoNote' ||
    'historyKindAnimation' => HeroAppIcons.video,
    'historyKindVoice' => HeroAppIcons.microphone,
    'historyKindAudio' => HeroAppIcons.music,
    'historyKindDocument' => HeroAppIcons.file,
    'historyKindSticker' => HeroAppIcons.faceSmile,
    _ => HeroAppIcons.image,
  };
}
