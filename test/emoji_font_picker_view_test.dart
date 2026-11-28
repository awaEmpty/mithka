import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/appearance_view.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/emoji_channel_source.dart';
import 'package:mithka/theme/emoji_font_catalog.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

/// The emoji font picker round: 系统默认 first / apple second / rest
/// alphabetical, downloaded packs show 已下载 · size, swipe-to-delete clears
/// the cached file. The manifest rides the fake channel source.
void main() {
  setUpAll(() => L10nFixtures.load().install());
  TestWidgetsFlutterBinding.ensureInitialized();

  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temporary;

  setUpAll(() async {
    EmojiFontCatalog.debugSkipEngineFontLoad = true;
    temporary = await Directory.systemTemp.createTemp('emoji_picker_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (call) async => temporary.path);
  });

  tearDownAll(() async {
    EmojiFontCatalog.debugSkipEngineFontLoad = false;
    try {
      await temporary.delete(recursive: true);
    } catch (_) {}
  });

  late EmojiFontCatalog pickerCatalog;
  late _FakeChannelSource channel;

  List<EmojiFontManifestEntry> channelEntries() => const [
    EmojiFontManifestEntry(
      key: 'apple',
      label: 'Apple Color Emoji',
      license: 'Apple',
      chatId: -100,
      channelMessageId: 23,
      channelPreviewMessageId: 22,
      sizeBytes: 63,
    ),
    EmojiFontManifestEntry(
      key: 'twemoji',
      label: 'Twemoji',
      license: 'CC-BY-4.0',
      chatId: -100,
      channelMessageId: 49,
      sizeBytes: 512,
    ),
    EmojiFontManifestEntry(
      key: 'blobmoji',
      label: 'Blobmoji',
      license: 'OFL-1.1',
      chatId: -100,
      channelMessageId: 24,
      sizeBytes: 2048,
    ),
    EmojiFontManifestEntry(
      key: 'cursed',
      label: 'Cursed Noto',
      license: 'MIT',
      chatId: -100,
      channelMessageId: 26,
      sizeBytes: 4096,
    ),
    EmojiFontManifestEntry(
      key: 'openmoji',
      label: 'OpenMoji',
      license: 'CC-BY-SA-4.0',
      chatId: -100,
      channelMessageId: 34,
      sizeBytes: 4096,
    ),
  ];

  Future<void> pumpPicker(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs, emojiFontCatalog: pickerCatalog);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: [AppColors.light]),
          home: EmojiFontPickerView(
            manifestOverride: Future.value(channelEntries()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('row order: system, apple, then alphabetical', (tester) async {
    channel = _FakeChannelSource();
    pickerCatalog = EmojiFontCatalog.forTesting()..debugChannelSource = channel;
    await pumpPicker(tester);
    expect(find.text('System default'), findsOneWidget);
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    final order = [
      for (final label in labels)
        if ([
          'System default',
          'Apple Color Emoji',
          'Blobmoji',
          'OpenMoji',
          'Twemoji',
        ].contains(label))
          label,
    ];
    expect(order, [
      'System default',
      'Apple Color Emoji',
      'Blobmoji',
      'OpenMoji',
      'Twemoji',
    ]);
  });

  testWidgets('download state captions flip after a download', (tester) async {
    channel = _FakeChannelSource({23: List.filled(63, 1)});
    pickerCatalog = EmojiFontCatalog.forTesting()..debugChannelSource = channel;
    await pumpPicker(tester);
    final appleRow = find.text('Apple Color Emoji');
    expect(appleRow, findsOneWidget);
    final appleCenter = tester.getCenter(appleRow);
    await tester.tapAt(appleCenter);
    await tester.pump(const Duration(milliseconds: 200));
    // testWidgets runs fake-async: pump until the download lands on the real
    // event loop and the caption flips (voice-recording suite's pattern).
    for (var attempt = 0; attempt < 100; attempt++) {
      if (find.text('Downloaded · 63 B').evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Downloaded · 63 B'), findsOneWidget);
  });

  // The last-resort preview face is the system 🐧 emoji glyph, never the
  // fork's brand-mark asset — unknown keys and failed assets both land
  // there (regression: the fallback used to be assets/brand_mark.png).
  testWidgets('unmapped keys fall back to the system penguin emoji', (
    tester,
  ) async {
    channel = _FakeChannelSource();
    pickerCatalog = EmojiFontCatalog.forTesting()..debugChannelSource = channel;
    await pumpPicker(tester);
    // 'cursed' has no bundled preview asset and no channel preview id, and
    // the system row also renders the system penguin — expect at least one
    // penguin face, never the fork's brand-mark asset.
    final penguin = find.text('\u{1F427}');
    expect(penguin, findsAtLeast(1));
    final style = tester.widget<Text>(penguin.first).style;
    expect(style?.fontFamily, isNotNull);
    // No row anywhere renders the fork logo as a preview face.
    expect(
      find.byWidgetPredicate((w) {
        if (w is! Image || w.image is! AssetImage) return false;
        return (w.image as AssetImage).assetName == 'assets/brand_mark.png';
      }),
      findsNothing,
    );
  });
}

/// Scripted channel source for the picker: serves the catalog plus whatever
/// font bodies a test seeds, keyed by message id.
class _FakeChannelSource implements EmojiChannelSource {
  _FakeChannelSource([Map<int, List<int>>? fonts]) : _fonts = fonts ?? {};

  final Map<int, List<int>> _fonts;

  @override
  Future<List<EmojiFontManifestEntry>?> fetchCatalog() async => const [];

  @override
  Future<int?> downloadFont({
    required int chatId,
    required int messageId,
    required String destPath,
    void Function(double progress)? onProgress,
  }) async {
    final bytes = _fonts[messageId];
    if (bytes == null) return null;
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
