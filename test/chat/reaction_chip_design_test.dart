//
//  reaction_chip_design_test.dart
//
//  Reaction chips follow the reference client's `ReactionsLayoutInBubble`:
//  26dp tall, pill corners, a translucent fill with NO border, a 13sp count,
//  and — the visible difference — a small bucket shows its reactors' avatars
//  instead of a number. A private chat always does (the two participants), a
//  group only while the message carries at most three reactors in total.
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_reaction_chips.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _message({
  int chatId = 7,
  List<MessageReaction> reactions = const [],
}) {
  final message = ChatMessage(
    id: 5,
    chatId: chatId,
    isOutgoing: false,
    senderId: 9,
    text: 'hello',
    date: 1700000000,
    contentType: 'messageText',
  );
  message.reactions = reactions;
  return message;
}

Future<void> _pump(
  WidgetTester tester,
  ChatMessage message, {
  String meName = 'Me',
  String peerTitle = 'Alice',
}) async {
  SharedPreferences.setMockInitialValues({});
  final theme = ThemeController(await SharedPreferences.getInstance());
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: MessageReactionChips(
              message: message,
              outgoing: false,
              meId: 1,
              meName: meName,
              peerTitle: peerTitle,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('a chip is a 26dp pill with a translucent fill and no border', (
    tester,
  ) async {
    await _pump(
      tester,
      _message(
        // A group keeps the count for a bucket this size, so the chip's own
        // number style is what this test can read.
        chatId: -1001234567890,
        reactions: const [MessageReaction(emoji: '👍', count: 4, chosen: true)],
      ),
    );
    final chip = find.byKey(const ValueKey('reactionChip-5-emoji:👍'));
    expect(chip, findsOneWidget);
    final box = tester.widget<Container>(
      find.descendant(of: chip, matching: find.byType(Container)).first,
    );
    expect(tester.getSize(chip).height, 26);
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.border, isNull, reason: 'the reference draws no border');
    expect(
      (decoration.borderRadius! as BorderRadius).topLeft.x,
      13,
      reason: 'a 26dp chip rounds to a pill',
    );
    // The count is 13sp, semibold, in the chip's own ink.
    final count = tester.widget<Text>(find.text('4'));
    expect(count.style?.fontSize, 13);
    expect(count.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('a private chat replaces the count with both participants', (
    tester,
  ) async {
    await _pump(
      tester,
      _message(
        reactions: const [MessageReaction(emoji: '❤️', count: 2, chosen: true)],
      ),
    );
    expect(find.byKey(const ValueKey('reactionAvatars-5')), findsOneWidget);
    expect(find.text('2', findRichText: true), findsNothing);
    // Both faces are drawn: one per participant.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reactionAvatars-5')),
        matching: find.byType(PhotoAvatar),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('a single chosen bucket shows only the reader', (tester) async {
    await _pump(
      tester,
      _message(
        reactions: const [MessageReaction(emoji: '👍', count: 1, chosen: true)],
      ),
    );
    expect(find.byKey(const ValueKey('reactionAvatars-5')), findsOneWidget);
    expect(find.text('1', findRichText: true), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reactionAvatars-5')),
        matching: find.byType(PhotoAvatar),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a group keeps the count once the bucket is bigger than three', (
    tester,
  ) async {
    await _pump(
      tester,
      _message(
        chatId: -1001234567890,
        reactions: const [
          MessageReaction(emoji: '🔥', count: 9, chosen: false),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('reactionAvatars-5')), findsNothing);
    expect(find.text('9', findRichText: true), findsOneWidget);
  });

  testWidgets('a group sorts its buckets by count', (tester) async {
    await _pump(
      tester,
      _message(
        chatId: -1001234567890,
        reactions: const [
          MessageReaction(emoji: '👍', count: 2, chosen: false),
          MessageReaction(emoji: '🔥', count: 7, chosen: true),
        ],
      ),
    );
    final chips = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('reactionChip-'),
    );
    final keys = [
      for (final element in chips.evaluate())
        (element.widget.key! as ValueKey<String>).value,
    ];
    expect(keys, ['reactionChip-5-emoji:🔥', 'reactionChip-5-emoji:👍']);
  });

  testWidgets('a private chat leads with the chosen bucket', (tester) async {
    await _pump(
      tester,
      _message(
        reactions: const [
          MessageReaction(emoji: '👍', count: 5, chosen: false),
          MessageReaction(emoji: '❤️', count: 1, chosen: true),
        ],
      ),
    );
    final chips = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('reactionChip-'),
    );
    final keys = [
      for (final element in chips.evaluate())
        (element.widget.key! as ValueKey<String>).value,
    ];
    expect(keys, ['reactionChip-5-emoji:❤️', 'reactionChip-5-emoji:👍']);
  });
}
