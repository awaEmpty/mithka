import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app mark: one flat glyph, filled at paint time with a gradient built
/// from the theme's brand colour.
///
/// Nothing is baked into an asset, so the mark follows 外观 → 主题颜色 and the
/// light/dark appearance together:
///
///  * Light surfaces get the brand's own ladder — lighter, base, deep — the
///    same shading [AppTheme.applyBrand] derives for the outgoing bubble.
///  * Dark surfaces get that ladder lifted toward the brand's pale AZURE, not
///    toward white: a saturated fill on a near-black page still needs lift,
///    but a white mark stops being the app's mark at all (the user asked for
///    the white fill to go). With the default theme colour the dark mark is
///    the same blue family as the light one; a custom theme keeps its hue and
///    only gains lightness.
List<Color> brandMarkColors(Brightness brightness) {
  final base = AppTheme.brand;
  if (brightness == Brightness.dark) {
    // A pale tint of the brand itself: hue and saturation survive, lightness
    // rises. Never white — that was the mark's old dark fill.
    final hsl = HSLColor.fromColor(base);
    return [
      hsl.withLightness(0.76).withSaturation(0.72).toColor(),
      hsl.withLightness(0.58).withSaturation(0.86).toColor(),
    ];
  }
  final hsl = HSLColor.fromColor(base);
  return [
    hsl.withLightness((hsl.lightness + 0.13).clamp(0.0, 1.0)).toColor(),
    base,
    hsl.withLightness((hsl.lightness - 0.09).clamp(0.0, 1.0)).toColor(),
  ];
}

/// The share of a [BrandMark]'s box the glyph's ink fills, so a mark sitting
/// in a row keeps the weight the shipped rasters had.
const double _inkShare = 0.72;

/// Ink width over height: the glyph is 23 units wide on the 24 unit grid.
const double _aspect = 23 / 24;

/// The glyph on a 24 × 24 grid, vertically filling it and 23 units wide.
///
/// Traced from `tool/app_icons/mithkax_mark.svg`, the canonical geometry; a
/// change to either has to land in both.
final Path brandMarkGlyph = Path()
  ..moveTo(0.5, 9.354)
  ..cubicTo(0.5, 8.933, 0.5, 8.512, 0.67, 8.071)
  ..cubicTo(0.753, 7.855, 0.87, 7.652, 1.016, 7.472)
  ..cubicTo(1.313, 7.105, 1.678, 6.894, 2.043, 6.683)
  ..lineTo(12.394, 0.707)
  ..cubicTo(13.111, 0.293, 13.828, -0.121, 14.55, 0.033)
  ..cubicTo(14.854, 0.098, 15.131, 0.257, 15.339, 0.489)
  ..cubicTo(15.833, 1.037, 15.833, 1.865, 15.833, 2.692)
  ..lineTo(15.833, 5.191)
  ..cubicTo(15.833, 5.688, 15.833, 6.184, 16.13, 6.513)
  ..cubicTo(16.255, 6.652, 16.42, 6.748, 16.603, 6.787)
  ..cubicTo(17.036, 6.879, 17.466, 6.631, 17.896, 6.382)
  ..lineTo(20.061, 5.133)
  ..cubicTo(20.778, 4.719, 21.494, 4.305, 22.216, 4.459)
  ..cubicTo(22.521, 4.524, 22.797, 4.683, 23.006, 4.915)
  ..cubicTo(23.5, 5.463, 23.5, 6.291, 23.5, 7.119)
  ..lineTo(23.5, 19.072)
  ..cubicTo(23.5, 19.493, 23.5, 19.914, 23.33, 20.355)
  ..cubicTo(23.247, 20.572, 23.13, 20.774, 22.984, 20.955)
  ..cubicTo(22.687, 21.322, 22.322, 21.532, 21.957, 21.743)
  ..lineTo(19.272, 23.293)
  ..cubicTo(18.555, 23.707, 17.839, 24.121, 17.117, 23.967)
  ..cubicTo(16.812, 23.903, 16.535, 23.743, 16.327, 23.511)
  ..cubicTo(15.833, 22.963, 15.833, 22.135, 15.833, 21.308)
  ..lineTo(15.833, 18.809)
  ..cubicTo(15.833, 18.312, 15.833, 17.816, 15.537, 17.487)
  ..cubicTo(15.412, 17.348, 15.246, 17.252, 15.063, 17.213)
  ..cubicTo(14.63, 17.121, 14.2, 17.369, 13.77, 17.618)
  ..lineTo(11.606, 18.867)
  ..cubicTo(10.889, 19.281, 10.172, 19.695, 9.45, 19.541)
  ..cubicTo(9.146, 19.476, 8.869, 19.317, 8.661, 19.085)
  ..cubicTo(8.167, 18.537, 8.167, 17.709, 8.167, 16.881)
  ..lineTo(8.167, 14.382)
  ..cubicTo(8.167, 13.886, 8.167, 13.389, 7.87, 13.06)
  ..cubicTo(7.745, 12.922, 7.58, 12.826, 7.397, 12.787)
  ..cubicTo(6.964, 12.695, 6.534, 12.943, 6.104, 13.191)
  ..lineTo(3.939, 14.441)
  ..cubicTo(3.222, 14.855, 2.506, 15.268, 1.784, 15.115)
  ..cubicTo(1.479, 15.05, 1.203, 14.891, 0.994, 14.659)
  ..cubicTo(0.5, 14.111, 0.5, 13.283, 0.5, 12.455)
  ..close();

/// Paints [brandMarkGlyph] filled from the theme's brand colour.
///
/// The fill is derived from `AppTheme.brand` while building. A `const`
/// instance would be canonicalised, and the element would be skipped whenever
/// an ancestor rebuilt, so a theme-colour change would leave the old fill on
/// screen — both constructors stay non-const on purpose.
// ignore_for_file: prefer_const_constructors_in_immutables
class BrandMark extends StatelessWidget {
  /// A square [size] box whose ink fills [_inkShare] of it — the spacing the
  /// 1024 px rasters were drawn with, so existing layouts keep their weight.
  BrandMark({super.key, required double size, this.opacity = 1, this.colors})
    : box = size,
      ink = null;

  /// The ink exactly [ink] tall, with the box hugging it. For layouts that
  /// space the mark by its geometry rather than by a square slot.
  BrandMark.ink({super.key, required this.ink, this.opacity = 1, this.colors})
    : box = null;

  /// Square slot; the ink fills [_inkShare] of it. Null on [BrandMark.ink].
  final double? box;

  /// Ink height; the box hugs it. Null on the square constructor.
  final double? ink;

  /// Multiplies the fill's alpha, for watermarks.
  final double opacity;

  /// Overrides the theme-derived gradient (the splash keeps the pale one).
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final height = ink ?? box! * _inkShare;
    final fill = colors ?? brandMarkColors(Theme.of(context).brightness);
    return SizedBox(
      width: box ?? height * _aspect,
      height: box ?? height,
      child: Center(
        child: SizedBox(
          width: height * _aspect,
          height: height,
          child: CustomPaint(painter: _BrandMarkPainter(fill, opacity)),
        ),
      ),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  _BrandMarkPainter(this.colors, this.opacity);

  final List<Color> colors;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.height / 24);
    final paint = Paint()
      ..isAntiAlias = true
      ..shader = LinearGradient(
        colors: [
          for (final color in colors)
            color.withValues(alpha: color.a * opacity),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(const Rect.fromLTWH(0, 0, 24, 24));
    canvas.drawPath(brandMarkGlyph, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) =>
      old.opacity != opacity || !listEquals(old.colors, colors);
}
