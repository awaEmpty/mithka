//
//  instant_view_media.dart
//
//  Media blocks of an Instant View article: photos, videos, animations,
//  audio, voice notes, documents, covers, collages, slideshows, embedded
//  posts, chat links and maps. Each block keeps the article's reading width
//  and opens the app's existing viewers where one exists.
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../components/app_icons.dart';
import '../../components/document_file_icon.dart';
import '../../components/photo_avatar.dart';
import '../../l10n/app_localizations.dart';
import '../../tdlib/td_models.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';
import '../media/file_detail_view.dart';
import '../media/image_preview.dart';
import '../media/looping_video_view.dart';
import '../media/video_player_view.dart';
import '../media/voice_audio.dart';
import 'instant_view_blocks.dart';
import 'instant_view_links.dart';
import 'instant_view_models.dart';
import 'instant_view_text.dart';

const double _mediaRadius = 10;

/// Photo/video frame with a caption and credit underneath.
class IvMediaBlock extends StatelessWidget {
  const IvMediaBlock({
    super.key,
    required this.child,
    this.caption = const IvCaption(),
    this.ctx,
  });

  final Widget child;
  final IvCaption caption;
  final IvRenderContext? ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final captionText = ivTextToPlain(caption.text).trim();
    final creditText = ivTextToPlain(caption.credit).trim();
    if (captionText.isEmpty && creditText.isEmpty) return child;
    final style =
        ctx?.typography ??
        IvTypography(
          base: TextStyle(fontSize: 14, height: 1.35, color: c.textSecondary),
          accent: c.linkBlue,
          secondary: c.textSecondary,
          codeBackground: c.searchFill,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        if (captionText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: IvRichText(
              text: caption.text,
              style: style.copyWith(
                base: style.base.copyWith(color: c.textSecondary),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (creditText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: IvRichText(
              text: caption.credit,
              style: style.copyWith(
                base: style.base.copyWith(fontSize: 12, color: c.textTertiary),
              ),
              textAlign: TextAlign.end,
            ),
          ),
      ],
    );
  }
}

class IvSpoilerMedia extends StatefulWidget {
  const IvSpoilerMedia({super.key, required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  State<IvSpoilerMedia> createState() => _IvSpoilerMediaState();
}

class _IvSpoilerMediaState extends State<IvSpoilerMedia> {
  var _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _revealed) return widget.child;
    final c = context.colors;
    return GestureDetector(
      key: const ValueKey('instantViewSpoilerMedia'),
      onTap: () => setState(() => _revealed = true),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: widget.child,
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(_mediaRadius),
              ),
              child: Center(
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: c.navBar.withValues(alpha: 0.86),
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(
                    HeroAppIcons.eye,
                    size: 22,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IvPhotoView extends StatelessWidget {
  const IvPhotoView({
    super.key,
    required this.photo,
    required this.ctx,
    this.hasSpoiler = false,
  });

  final IvPhoto photo;
  final IvRenderContext ctx;
  final bool hasSpoiler;

  double get _aspectRatio {
    final width = photo.width ?? photo.media.width ?? 0;
    final height = photo.height ?? photo.media.height ?? 0;
    if (width <= 0 || height <= 0) return 16 / 9;
    return (width / height).clamp(0.4, 3.2);
  }

  @override
  Widget build(BuildContext context) {
    final ref = photo.media.image;
    final remote = photo.url?.trim() ?? '';
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(_mediaRadius),
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: ref != null
            ? TDImage(photo: ref, cornerRadius: 0, showProgress: true)
            : remote.isEmpty
            ? const ColoredBox(color: Color(0x11000000))
            : Image.network(
                remote,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: Color(0x11000000)),
              ),
      ),
    );
    if (ref == null) return image;
    return IvSpoilerMedia(
      enabled: hasSpoiler,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openImagePreview(context, items: [ref]),
        child: image,
      ),
    );
  }
}

class IvVideoView extends StatelessWidget {
  const IvVideoView({
    super.key,
    required this.video,
    required this.ctx,
    this.hasSpoiler = false,
    this.loop = false,
  });

  final IvVideo video;
  final IvRenderContext ctx;
  final bool hasSpoiler;
  final bool loop;

  double get _aspectRatio {
    final width = video.media.width ?? 0;
    final height = video.media.height ?? 0;
    if (width <= 0 || height <= 0) return 16 / 9;
    return (width / height).clamp(0.4, 3.2);
  }

  @override
  Widget build(BuildContext context) {
    final file = video.media.video;
    final poster = video.media.image;
    final child = ClipRRect(
      borderRadius: BorderRadius.circular(_mediaRadius),
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (loop && file != null)
              // LoopingVideoView asks for playback by itself only while it is
              // mounted, which is exactly the article's inline animation.
              LoopingVideoBody(file: file, fallback: poster)
            else
              TDImage(photo: poster, cornerRadius: 0),
            if (!loop)
              Center(
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const AppIcon(
                    HeroAppIcons.play,
                    size: 26,
                    color: Colors.white,
                  ),
                ),
              ),
            if (video.duration > 0)
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _durationLabel(video.duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return IvSpoilerMedia(
      enabled: hasSpoiler,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: file == null
            ? null
            : () => _openVideo(context, file, poster, video),
        child: child,
      ),
    );
  }

  void _openVideo(
    BuildContext context,
    TdFileRef file,
    TdFileRef? poster,
    IvVideo video,
  ) {
    Navigator.of(context).push<void>(
      AppPageRoute<void>(
        fullscreenDialog: true,
        pageBuilder: (routeContext, _, _) => ColoredBox(
          color: Colors.black,
          child: VideoPlayerView(
            video: file,
            accountSlot: ctx.accountSlot,
            thumb: poster,
            width: video.media.width,
            height: video.media.height,
            durationSeconds: video.duration,
            onClose: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    );
  }
}

/// Small wrapper so [IvVideoView] does not need to import the looping player
/// when the block is a still video.
class LoopingVideoBody extends StatelessWidget {
  const LoopingVideoBody({super.key, required this.file, this.fallback});

  final TdFileRef file;
  final TdFileRef? fallback;

  @override
  Widget build(BuildContext context) => LoopingVideoView(
    file: file,
    fallback: fallback,
    fit: BoxFit.cover,
    showDownloadProgress: true,
  );
}

String _durationLabel(int seconds) {
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
        '${rest.toString().padLeft(2, '0')}';
  }
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

class IvAudioBlockView extends StatefulWidget {
  const IvAudioBlockView({
    super.key,
    required this.audio,
    required this.ctx,
    this.voice = false,
  });

  final IvAudio audio;
  final IvRenderContext ctx;

  /// Voice notes use the voice codec; music blocks use the audio codec.
  final bool voice;

  @override
  State<IvAudioBlockView> createState() => _IvAudioBlockViewState();
}

class _IvAudioBlockViewState extends State<IvAudioBlockView> {
  late final VoicePlayer _player = VoicePlayer();

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayer);
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    unawaited(_player.stop());
    _player.dispose();
    super.dispose();
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  bool get _active => _player.isActive(widget.audio.file);

  Future<void> _toggle() async {
    final file = widget.audio.file;
    if (file == null) return;
    if (widget.voice) {
      await _player.toggleVoice(file);
    } else {
      await _player.toggleAudio(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final audio = widget.audio;
    final active = _active;
    final total = active && _player.total.inMilliseconds > 0
        ? _player.total.inSeconds
        : audio.duration;
    final position = active ? _player.position.inSeconds : 0;
    final progress = total <= 0 ? 0.0 : (position / total).clamp(0, 1);
    final title = widget.voice
        ? AppStrings.t(AppStringKeys.sharedMediaVoice)
        : audio.displayTitle.isEmpty
        ? AppStrings.t(AppStringKeys.composerAudio)
        : audio.displayTitle;
    final subtitle = [
      if (audio.performer.trim().isNotEmpty) audio.performer.trim(),
      if (!widget.voice &&
          audio.fileName.trim().isNotEmpty &&
          audio.fileName.trim() != audio.displayTitle)
        audio.fileName.trim(),
    ].join(String.fromCharCode(0x00B7));
    return Container(
      decoration: BoxDecoration(
        color: c.searchFill.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(_mediaRadius),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: SizedBox.square(
              dimension: 42,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (audio.cover != null)
                    ClipOval(
                      child: TDImage(photo: audio.cover, cornerRadius: 0),
                    )
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.brand.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: AppIcon(
                        widget.voice
                            ? HeroAppIcons.microphone
                            : HeroAppIcons.music,
                        size: 20,
                        color: AppTheme.brand,
                      ),
                    ),
                  Center(
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        shape: BoxShape.circle,
                      ),
                      child: _player.isLoading && active
                          ? const Padding(
                              padding: EdgeInsets.all(7),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : AppIcon(
                              active && _player.isPlaying
                                  ? HeroAppIcons.pause
                                  : HeroAppIcons.play,
                              size: 14,
                              color: Colors.white,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.body(
                    c.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption(c.textSecondary),
                  ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: active ? progress.toDouble() : 0,
                    minHeight: 3,
                    backgroundColor: c.divider,
                    color: AppTheme.brand,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _durationLabel(total),
            style: AppTextStyle.caption(c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class IvDocumentView extends StatelessWidget {
  const IvDocumentView({super.key, required this.document, required this.ctx});

  final IvDocument document;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = document.fileName.trim().isEmpty
        ? AppStrings.t(AppStringKeys.topicPostContentFile)
        : document.fileName.trim();
    final extension = name.contains('.') ? name.split('.').last : '';
    return Material(
      color: c.searchFill.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(_mediaRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(_mediaRadius),
        onTap: document.file == null
            ? null
            : () => Navigator.of(context).push<void>(
                AppPageRoute<void>(
                  pageBuilder: (_, _, _) => FileDetailView(
                    doc: MessageDocument(
                      fileName: name,
                      size: document.file?.size ?? 0,
                      ext: extension,
                      file: document.file,
                    ),
                    accountSlot: ctx.accountSlot,
                  ),
                ),
              ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              DocumentFileIcon(fileName: name, extension: extension, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.body(
                        c.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if ((document.file?.size ?? 0) > 0)
                      Text(
                        _fileSizeLabel(document.file!.size!),
                        style: AppTextStyle.caption(c.textSecondary),
                      ),
                  ],
                ),
              ),
              AppIcon(HeroAppIcons.download, size: 20, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

String _fileSizeLabel(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

class IvCollageView extends StatelessWidget {
  const IvCollageView({super.key, required this.blocks, required this.ctx});

  final List<IvBlock> blocks;
  final IvRenderContext ctx;

  List<TdFileRef> get _refs => [
    for (final block in blocks)
      if (block is IvPhotoBlock && block.photo.media.image != null)
        block.photo.media.image!,
  ];

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final block in blocks)
        if (block is IvPhotoBlock) block,
    ];
    if (photos.isEmpty) return const SizedBox.shrink();
    final refs = _refs;
    const gap = 2.0;
    final columns = photos.length >= 4 ? 2 : photos.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < photos.length; i++)
              () {
                final photo = photos[i];
                final w = photo.photo.media.width ?? 1;
                final h = photo.photo.media.height ?? 1;
                final height = (itemWidth * h / w).clamp(90, 220).toDouble();
                return SizedBox(
                  width: itemWidth,
                  height: height,
                  child: GestureDetector(
                    onTap: refs.isEmpty
                        ? null
                        : () => openImagePreview(
                            context,
                            items: refs,
                            startIndex: i.clamp(0, refs.length - 1),
                          ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TDImage(
                        photo: photo.photo.media.image,
                        cornerRadius: 0,
                      ),
                    ),
                  ),
                );
              }(),
          ],
        );
      },
    );
  }
}

class IvSlideshowView extends StatefulWidget {
  const IvSlideshowView({super.key, required this.blocks, required this.ctx});

  final List<IvBlock> blocks;
  final IvRenderContext ctx;

  @override
  State<IvSlideshowView> createState() => _IvSlideshowViewState();
}

class _IvSlideshowViewState extends State<IvSlideshowView> {
  late final PageController _controller = PageController();
  var _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final block in widget.blocks)
        if (block is IvPhotoBlock) block,
    ];
    if (photos.isEmpty) return const SizedBox.shrink();
    final refs = [
      for (final photo in photos)
        if (photo.photo.media.image != null) photo.photo.media.image!,
    ];
    final c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 250,
          child: PageView.builder(
            controller: _controller,
            itemCount: photos.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) {
              final photo = photos[index];
              return GestureDetector(
                onTap: refs.isEmpty
                    ? null
                    : () => openImagePreview(
                        context,
                        items: refs,
                        startIndex: index.clamp(0, refs.length - 1),
                      ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_mediaRadius),
                  child: TDImage(
                    photo: photo.photo.media.image,
                    cornerRadius: 0,
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          ),
        ),
        if (photos.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < photos.length && i < 12; i++)
                  Container(
                    width: i == _index ? 7 : 5,
                    height: i == _index ? 7 : 5,
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    decoration: BoxDecoration(
                      color: i == _index ? AppTheme.brand : c.textTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class IvEmbeddedView extends StatelessWidget {
  const IvEmbeddedView({super.key, required this.block, required this.ctx});

  final IvEmbeddedBlock block;
  final IvRenderContext ctx;

  String get _host {
    final uri = Uri.tryParse(block.url);
    final host = uri?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final poster = block.poster;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: block.url.isEmpty ? null : () => openIvUrl(context, block.url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (poster != null)
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(_mediaRadius),
                  child: AspectRatio(
                    aspectRatio: block.width > 0 && block.height > 0
                        ? (block.width / block.height).clamp(0.4, 3.2)
                        : 16 / 9,
                    child: TDImage(
                      photo: poster.media.image,
                      cornerRadius: 0,
                      showProgress: true,
                    ),
                  ),
                ),
                const Positioned.fill(child: Center(child: _EmbedPlayBadge())),
              ],
            )
          else
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.searchFill.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(_mediaRadius),
              ),
              child: Row(
                children: [
                  AppIcon(HeroAppIcons.globe, size: 20, color: c.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _host.isEmpty ? block.url : _host,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.body(c.textPrimary),
                    ),
                  ),
                  AppIcon(
                    HeroAppIcons.arrowTopRight,
                    size: 18,
                    color: c.textTertiary,
                  ),
                ],
              ),
            ),
          if (_host.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption(c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmbedPlayBadge extends StatelessWidget {
  const _EmbedPlayBadge();

  @override
  Widget build(BuildContext context) => Container(
    width: 54,
    height: 54,
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.45),
      shape: BoxShape.circle,
    ),
    child: const AppIcon(
      HeroAppIcons.arrowTopRight,
      size: 24,
      color: Colors.white,
    ),
  );
}

class IvEmbeddedPostView extends StatelessWidget {
  const IvEmbeddedPostView({super.key, required this.block, required this.ctx});

  final IvEmbeddedPostBlock block;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final author = block.author.trim();
    return Container(
      decoration: BoxDecoration(
        color: c.searchFill.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(_mediaRadius),
        border: Border.all(color: c.divider, width: AppMetric.divider),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 34,
                  child: block.authorPhoto?.media.image != null
                      ? TDImage(
                          photo: block.authorPhoto!.media.image,
                          cornerRadius: 0,
                        )
                      : ColoredBox(
                          color: AppTheme.brand.withValues(alpha: 0.16),
                          child: Center(
                            child: Text(
                              author.isEmpty
                                  ? '?'
                                  : author.characters.first.toUpperCase(),
                              style: AppTextStyle.body(
                                c.textPrimary,
                              ).copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (author.isNotEmpty)
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.callout(
                          c.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    if (block.date > 0)
                      Text(
                        formatIvDate(context, block.date),
                        style: AppTextStyle.caption(c.textSecondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (block.blocks.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final nested in block.blocks)
              IvBlockView(
                block: nested,
                ctx: ctx.copyWith(
                  base: ctx.typography.base.copyWith(fontSize: 15),
                  compact: true,
                  applyGutter: false,
                ),
              ),
          ],
          if (block.url.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openIvUrl(context, block.url),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    AppStrings.t(AppStringKeys.instantViewOpenInBrowser),
                    style: AppTextStyle.caption(
                      AppTheme.brand,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 3),
                  AppIcon(
                    HeroAppIcons.arrowTopRight,
                    size: 13,
                    color: AppTheme.brand,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class IvChatLinkView extends StatelessWidget {
  const IvChatLinkView({super.key, required this.block, required this.ctx});

  final IvChatLinkBlock block;
  final IvRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final username = block.username.trim().replaceFirst('@', '');
    return Material(
      color: c.searchFill.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(_mediaRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(_mediaRadius),
        onTap: username.isEmpty
            ? null
            : () => openIvUrl(context, 'https://t.me/$username'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 42,
                  child: block.photo?.media.image != null
                      ? TDImage(
                          photo: block.photo!.media.image,
                          cornerRadius: 0,
                        )
                      : ColoredBox(
                          color: AppTheme.brand.withValues(alpha: 0.16),
                          child: AppIcon(
                            HeroAppIcons.users,
                            size: 20,
                            color: AppTheme.brand,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      block.title.isEmpty ? username : block.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.body(
                        c.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (username.isNotEmpty)
                      Text(
                        '@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.caption(c.textSecondary),
                      ),
                  ],
                ),
              ),
              AppIcon(
                HeroAppIcons.chevronRight,
                size: 16,
                color: c.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class IvMapView extends StatelessWidget {
  const IvMapView({super.key, required this.block, required this.ctx});

  final IvMapBlock block;
  final IvRenderContext ctx;

  String get _mapUrl {
    final zoom = block.zoom > 0 ? block.zoom : 15;
    return 'https://www.openstreetmap.org/?mlat=${block.latitude}'
        '&mlon=${block.longitude}#map=$zoom/${block.latitude}/${block.longitude}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openIvUrl(context, _mapUrl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_mediaRadius),
        child: Container(
          height: 170,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                c.searchFill.withValues(alpha: 0.55),
                AppTheme.brand.withValues(alpha: 0.12),
              ],
            ),
          ),
          child: CustomPaint(
            painter: _IvMapGridPainter(color: c.divider),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    HeroAppIcons.locationPin,
                    size: 32,
                    color: AppTheme.brand,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${block.latitude.toStringAsFixed(4)}, '
                    '${block.longitude.toStringAsFixed(4)}',
                    style: AppTextStyle.caption(c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IvMapGridPainter extends CustomPainter {
  const _IvMapGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    const step = 34.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_IvMapGridPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Formats a Unix timestamp as a localized date; unparseable stamps render
/// empty instead of throwing inside a list row.
String formatIvDate(BuildContext context, int unixTime) {
  if (unixTime <= 0) return '';
  final locale = Localizations.localeOf(context).toString();
  final date = DateTime.fromMillisecondsSinceEpoch(unixTime * 1000);
  try {
    return DateFormat.yMMMMd(locale).format(date);
  } catch (_) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
