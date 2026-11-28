//
//  l10n_untranslated_english_test.dart
//
//  The sticker studio, suggested posts, checklist/poll/story actions, shared
//  contacts, topic-chat actions and app-icon names shipped with the English
//  source value in every translation. These groups are now translated; the
//  only values allowed to stay identical to English are words that are the
//  same in that language (brand names, "Link" in German, "Message" in French).
//

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _locales = [
  'de-DE',
  'es-ES',
  'fr-FR',
  'ja-JP',
  'ko-KR',
  'zh-Hans-CN',
  'zh-Hant-TW',
];

/// Keys whose English value is already the natural word in these languages.
const _languageNeutral = {
  'suggestedPostStars', // Telegram Stars
  'suggestedPostTon', // TON
  'storyAuthoringAreaLink', // Link (de)
  'storyAuthoringChatValue1', // Chat {value1} (de/es)
  'storyAuthoringContentVideo', // Video (de)
  'storyManagementStoryValue1', // Story {value1} (de)
  'storyManagementAlbumCount', // {value1} stories (fr)
  'stickerStudioTypeRegular', // Stickers (es)
  'sharedContactMessage', // Message (fr)
  'storyAuthoringAreaMessage', // Message (fr)
  'storyAuthoringContentDocument', // Document (fr)
  'storyAuthoringContentMessage', // Message (fr)
  'storyAuthoringContentPhoto', // Photo (fr)
  'storyManagementAlbums', // Albums (fr)
};

const _coveredPrefixes = [
  'stickerStudio',
  'suggestedPost',
  'messageChecklist',
  'messagePoll',
  'messageStory',
  'story',
  'sharedContact',
  'topicChat',
  'composerMediaSearch',
  'contactShareEmpty',
  'appIconMotif',
];

/// Formats that carry no words of their own.
const _untranslatable = {
  'stickerStudioLinkPrefixEmoji',
  'stickerStudioLinkPrefixStickers',
  'stickerStudioFormatFile',
  'scheduledMessagesContentAnimation',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, String>> catalogue(String tag) async {
    final raw = await rootBundle.loadString('assets/l10n/$tag.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (json['strings'] as Map<String, dynamic>).cast<String, String>();
  }

  test('the covered groups carry no English leftovers', () async {
    final source = await catalogue('en-US');
    final keys = source.keys
        .where(
          (key) =>
              _coveredPrefixes.any(key.startsWith) ||
              key == 'linkHandlerStarsCountValue1',
        )
        .where((key) => !_untranslatable.contains(key))
        .toList();
    expect(keys.length, greaterThan(300));

    for (final locale in _locales) {
      final translated = await catalogue(locale);
      final leftovers = [
        for (final key in keys)
          if (translated[key] == source[key] && !_languageNeutral.contains(key))
            key,
      ];
      expect(
        leftovers,
        isEmpty,
        reason: '$locale still carries the English source for $leftovers',
      );
    }
  });

  test(
    'the sticker studio and suggested posts read naturally in Chinese',
    () async {
      final zh = await catalogue('zh-Hans-CN');
      expect(zh['stickerStudioTitle'], '贴纸工作室');
      expect(zh['stickerStudioValidationAnimatedDuration'], '动画贴纸时长不能超过 3 秒。');
      expect(zh['stickerStudioTypeCustomEmoji'], '自定义表情符号');
      expect(zh['suggestedPostApprove'], '批准');
      expect(zh['suggestedPostDeclineTitle'], '拒绝建议帖子');
      expect(zh['messagePollStop'], '关闭投票');
      expect(zh['topicChatMarkAllRead'], '全部标为已读');
    },
  );
}
