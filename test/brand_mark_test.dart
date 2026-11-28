//
//  brand_mark_test.dart
//
//  The mark's fill is derived from the theme's brand colour at paint time, so
//  these tests set a brand colour nobody would pick by accident and read it
//  back out of the painted pixels. A fill that quietly stopped following the
//  brand (back to a baked asset, a const widget skipped on rebuild) fails here.
//

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/brand_mark.dart';
import 'package:mithka/theme/app_theme.dart';

const _brandKey = ValueKey('brand-mark-capture');

/// Pumps [mark] on white and returns its opaque pixels as RGB triples.
Future<List<List<int>>> _paint(WidgetTester tester, Widget mark) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: RepaintBoundary(
          key: _brandKey,
          child: Center(child: mark),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_brandKey),
  );
  late final List<List<int>> pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    final bytes = data!.buffer.asUint8List();
    final out = <List<int>>[];
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i + 3] < 250) continue;
      final rgb = [bytes[i], bytes[i + 1], bytes[i + 2]];
      // Skip the white page itself.
      if (rgb[0] > 250 && rgb[1] > 250 && rgb[2] > 250) continue;
      out.add(rgb);
    }
    image.dispose();
    pixels = out;
  });
  return pixels;
}

List<double> _mean(List<List<int>> pixels) {
  final totals = [0.0, 0.0, 0.0];
  for (final pixel in pixels) {
    for (var i = 0; i < 3; i++) {
      totals[i] += pixel[i];
    }
  }
  return [for (final total in totals) total / pixels.length];
}

void main() {
  tearDown(() => AppTheme.applyBrand(const Color(AppTheme.defaultBrand)));

  test('the fill follows the theme brand colour', () {
    AppTheme.applyBrand(const Color(0xFFE0443E));

    final light = brandMarkColors(Brightness.light);
    expect(light[1], const Color(0xFFE0443E));
    expect(
      light[0].computeLuminance(),
      greaterThan(light[1].computeLuminance()),
      reason: 'the top-left stop lifts the brand',
    );
    expect(
      light[2].computeLuminance(),
      lessThan(light[1].computeLuminance()),
      reason: 'the bottom-right stop deepens it',
    );

    // Dark surfaces get the same ramp lifted toward the brand's pale azure,
    // not toward white: the mark stays recognisably the brand's own hue.
    final dark = brandMarkColors(Brightness.dark);
    for (final stop in dark) {
      final hsl = HSLColor.fromColor(stop);
      expect(
        hsl.saturation,
        greaterThan(0.5),
        reason: 'a white/grey fill has no saturation left: $stop',
      );
    }
    expect(
      dark[1].computeLuminance(),
      greaterThan(dark[0].computeLuminance() * 0.4),
    );
    expect(
      HSLColor.fromColor(dark[0]).hue,
      closeTo(HSLColor.fromColor(const Color(0xFFE0443E)).hue, 1),
      reason: 'the dark stops keep the theme hue',
    );
  });

  test('the dark fill is never white', () {
    AppTheme.applyBrand(const Color(AppTheme.defaultBrand));
    for (final stop in brandMarkColors(Brightness.dark)) {
      expect(
        stop.computeLuminance(),
        lessThan(0.62),
        reason: 'the old white fill must stay gone: $stop',
      );
    }
  });

  testWidgets('a green brand paints a green mark', (tester) async {
    AppTheme.applyBrand(const Color(0xFF1F9E4B));

    final pixels = await _paint(tester, BrandMark(size: 120));
    expect(pixels, isNotEmpty);
    final mean = _mean(pixels);
    expect(mean[1], greaterThan(mean[0] + 40), reason: 'mean $mean');
    expect(mean[1], greaterThan(mean[2] + 40), reason: 'mean $mean');
  });

  testWidgets('the fill is a gradient, not one flat colour', (tester) async {
    AppTheme.applyBrand(const Color(0xFF1F9E4B));

    final pixels = await _paint(tester, BrandMark(size: 120));
    final greens = pixels.map((pixel) => pixel[1]).toSet();
    expect(
      greens.length,
      greaterThan(8),
      reason: 'a flat fill would give one value',
    );
  });

  testWidgets('the square slot keeps the ink at 72% of its box', (
    tester,
  ) async {
    await tester.pumpWidget(Center(child: BrandMark(size: 100)));
    expect(tester.getSize(find.byType(BrandMark)), const Size(100, 100));

    final ink = tester.getSize(
      find.descendant(
        of: find.byType(BrandMark),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(ink.height, closeTo(72, 0.01));
    expect(ink.width / ink.height, closeTo(23 / 24, 0.001));
  });

  testWidgets('the ink constructor hugs the glyph', (tester) async {
    await tester.pumpWidget(Center(child: BrandMark.ink(ink: 84)));
    final box = tester.getSize(find.byType(BrandMark));
    expect(box.height, 84);
    expect(box.width, closeTo(84 * 23 / 24, 0.01));
  });
}
