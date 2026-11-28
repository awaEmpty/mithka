//
//  sticker_size_settings_view.dart
//
//  One size preference for stickers and GIFs in the transcript, matching
//  exteraless's sticker-size slider (2..20, default 14 → 20%..140%). The
//  slider moves in 5% steps; both preview rows scale with it so the choice is
//  visible before leaving the page.
//

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../components/app_icons.dart';
import '../../components/brand_mark.dart';
import '../../components/ui_components.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';

class StickerSizeSettingsView extends StatelessWidget {
  const StickerSizeSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final colors = context.colors;
    final scale = theme.stickerMediaScale;
    final percent = (scale * 100).round();
    return SettingsPageScaffold(
      key: const ValueKey('sticker-size-settings-page'),
      title: AppStrings.t(AppStringKeys.mithkaxStickerSizeTitle),
      onBack: () => Navigator.of(context).pop(),
      child: SettingsListView(
        children: [
          SettingsPanel(
            key: const ValueKey('sticker-size-preview'),
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _Sample(
                    label: AppStrings.t(AppStringKeys.historyKindSticker),
                    child: BrandMark(size: (58 * scale).clamp(12, 82)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _Sample(
                    label: AppStrings.t(AppStringKeys.historyKindAnimation),
                    child: _GifSample(
                      width: (132 * scale).clamp(26, 185),
                      height: (86 * scale).clamp(18, 120),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SettingsNote(
            text: AppStrings.t(AppStringKeys.mithkaxStickerSizeNote),
          ),
          const SizedBox(height: AppSpacing.sm),
          SettingsPanel(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SettingsLeadingIcon(icon: HeroAppIcons.faceSmile),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        AppStrings.t(AppStringKeys.mithkaxStickerSizeTitle),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '$percent%',
                      key: const ValueKey('sticker-size-percent'),
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  height: 44,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: AppTheme.brand,
                      inactiveTrackColor: colors.divider,
                      thumbColor: colors.card,
                      overlayColor: AppTheme.brand.withValues(alpha: 0.12),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 9,
                        elevation: 2,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 20,
                      ),
                      tickMarkShape: SliderTickMarkShape.noTickMark,
                    ),
                    child: Slider(
                      key: const ValueKey('sticker-size-slider'),
                      value: percent.toDouble().clamp(20, 140),
                      min: 20,
                      max: 140,
                      divisions: 24,
                      onChanged: (value) => theme.stickerMediaSize =
                          14 + (value - 100) * 15 / 100,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    children: [
                      Text(
                        AppStrings.t(AppStringKeys.mithkaxStickerSizeSmall),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textTertiary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        AppStrings.t(AppStringKeys.mithkaxStickerSizeLarge),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey('sticker-size-reset'),
                    onPressed: () => theme.stickerMediaSize = 14,
                    child: Text(
                      AppStrings.t(AppStringKeys.mithkaxStickerSizeReset),
                      style: TextStyle(color: colors.linkBlue, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sample extends StatelessWidget {
  const _Sample({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 120, child: Center(child: child)),
        const SizedBox(height: 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// A chat-GIF stand-in: a rounded card with the play glyph, sized by the
/// preference like a real animation bubble.
class _GifSample extends StatelessWidget {
  const _GifSample({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.brand.withValues(alpha: 0.30), colors.card],
        ),
      ),
      child: Center(
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.36),
          ),
          child: const AppIcon(
            HeroAppIcons.play,
            size: 14,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
