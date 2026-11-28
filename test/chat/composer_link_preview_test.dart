//
//  composer_link_preview_test.dart
//
//  The composer's link preview row (the reference client's link preview panel
//  above the field): it appears while the draft carries a previewable link,
//  turns the card off for this message, and switches which side of the text
//  the card is drawn on. The choice travels to the send request as
//  `linkPreviewOptions` — that half is pinned in the unit test below.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/composer/chat_input_bar.dart';
import 'package:mithka/chat/links_search/link_preview_fixer.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LinkPreviewTestChatViewModel extends ChatViewModel {
  _LinkPreviewTestChatViewModel()
    : super(chatId: 1, title: 'Test', markReadOnOpen: false);

  @override
  void sendTyping() {}

  @override
  void setDraft(
    String value, {
    String? formattedText,
    List<Map<String, dynamic>> entities = const [],
  }) {
    draft = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ChatViewModel> pumpComposer(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    final vm = _LinkPreviewTestChatViewModel();
    addTearDown(theme.dispose);
    addTearDown(vm.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: [AppColors.light]),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(
                vm: vm,
                onStartCall: (_) {},
                onMessageSent: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return vm;
  }

  testWidgets('a typed link opens the preview row above the field', (
    tester,
  ) async {
    final vm = await pumpComposer(tester);
    expect(
      find.byKey(const ValueKey('composerLinkPreviewBanner')),
      findsNothing,
    );

    await tester.enterText(
      find.byType(TextField),
      'look https://example.com/a-post',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('composerLinkPreviewBanner')),
      findsOneWidget,
    );
    expect(find.text('example.com'), findsOneWidget);
    expect(vm.composerLinkPreview, isNotNull);
    expect(vm.composerLinkPreview!.enabled, isTrue);
    expect(vm.composerLinkPreview!.showAboveText, isFalse);

    // The row hangs directly above the input row, never over the transcript.
    final banner = tester.getRect(
      find.byKey(const ValueKey('composerLinkPreviewBanner')),
    );
    final field = tester.getRect(find.byType(TextField));
    expect(banner.bottom, lessThanOrEqualTo(field.top + 1));
  });

  testWidgets('the close button turns the preview off for this message', (
    tester,
  ) async {
    final vm = await pumpComposer(tester);
    await tester.enterText(find.byType(TextField), 'https://example.com/x');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('composerLinkPreviewClose')));
    await tester.pump();
    expect(vm.composerLinkPreview!.enabled, isFalse);
    expect(find.text('Link preview off'), findsOneWidget);

    // Editing the link away and back starts a fresh link with previews on
    // again, exactly like the reference client's per-link preview state.
    await tester.enterText(find.byType(TextField), 'no link here');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composerLinkPreviewBanner')),
      findsNothing,
    );
    expect(vm.composerLinkPreview, isNull);

    await tester.enterText(find.byType(TextField), 'https://example.com/y');
    await tester.pump();
    expect(vm.composerLinkPreview!.enabled, isTrue);
  });

  testWidgets('the menu moves the card above or below the text', (
    tester,
  ) async {
    final vm = await pumpComposer(tester);
    await tester.enterText(find.byType(TextField), 'https://example.com/x');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('composerLinkPreviewBanner')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('app-anchored-menu-link-preview-position')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('app-anchored-menu-link-preview-position')),
    );
    await tester.pumpAndSettle();
    expect(vm.composerLinkPreview!.showAboveText, isTrue);

    // The row's label names the side the card is on now.
    await tester.tap(find.byKey(const ValueKey('composerLinkPreviewBanner')));
    await tester.pumpAndSettle();
    expect(find.text('Preview below the text'), findsOneWidget);
  });

  test('the send request carries the panel choice', () {
    const choice = ComposerLinkPreviewChoice(
      enabled: false,
      showAboveText: true,
    );
    final request = {
      '@type': 'sendMessage',
      'chat_id': 1,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': 'see https://example.com/x'},
      },
    };
    final patched = LinkPreviewFixer.shared.applyTo(request, choice: choice);
    final content = patched['input_message_content'] as Map<String, dynamic>;
    final options = content['link_preview_options'] as Map<String, dynamic>;
    expect(options['is_disabled'], isTrue);
    expect(options['show_above_text'], isTrue);

    const above = ComposerLinkPreviewChoice(enabled: true, showAboveText: true);
    final enabled = LinkPreviewFixer.shared.applyTo(request, choice: above);
    final enabledOptions =
        (enabled['input_message_content']
                as Map<String, dynamic>)['link_preview_options']
            as Map<String, dynamic>;
    expect(enabledOptions['is_disabled'], isFalse);
    expect(enabledOptions['show_above_text'], isTrue);

    // A message without a link keeps its request untouched.
    final plain = {
      '@type': 'sendMessage',
      'chat_id': 1,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': 'no links'},
      },
    };
    expect(LinkPreviewFixer.shared.applyTo(plain, choice: choice), same(plain));
  });
}
