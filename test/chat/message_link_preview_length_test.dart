//
//  message_link_preview_length_test.dart
//
//  exteraless caps a link preview's description at six lines. A Telegraph
//  article or a mirrored tweet used to stretch the card down half the
//  transcript because mithka laid the description out unbounded.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_bubble.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _description =
    'Telegram is a cloud-based mobile and desktop messaging app with a focus '
    'on security and speed. It is super-fast, simple and free. You can use '
    'Telegram on all your devices at the same time — your messages sync '
    'seamlessly across any number of phones, tablets or computers. Telegram '
    'has no limits on the size of your media and chats.';

void main() {
  testWidgets('a long link description is capped at six lines', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: [AppColors.light]),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: MessageBubble(
                  message: ChatMessage(
                    id: 11,
                    isOutgoing: false,
                    text: 'https://telegra.ph/story',
                    date: 1700000000,
                    contentType: 'messageText',
                    linkPreview: const MessageLinkPreview(
                      url: 'https://telegra.ph/story',
                      displayUrl: 'telegra.ph/story',
                      siteName: 'Telegraph',
                      title: 'How Telegram works',
                      description: _description,
                    ),
                  ),
                  peerTitle: 'Chat',
                  isGroup: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final rich = tester.widgetList<RichText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('cloud-based mobile'),
      ),
    );
    expect(rich, isNotEmpty);
    expect(
      rich.first.maxLines,
      messageLinkPreviewDescriptionMaxLines,
      reason: 'the reference client lays the description out with 6 lines',
    );
    expect(rich.first.overflow, isNot(TextOverflow.visible));
  });
}
