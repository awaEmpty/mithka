//
//  auto_translate_viewport_test.dart
//
//  exteraless translates only the messages around the viewport (±7 ids) and
//  loads the next page's translations when scrolling brings it in. The fork
//  used to walk the whole loaded history in the background, which translated
//  messages the user never looked at and still left the viewport waiting
//  behind older pages.
//
//  The same file pins exteraless's chat-classification thresholds: a chat is
//  offered "translate this chat" from per-message language evidence, not from
//  one dominant-language guess.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/ai_translation/auto_translate_policy.dart';
import 'package:mithka/tdlib/td_models.dart';

ChatMessage _message(
  int id, {
  String? translation,
  String? translationLanguage,
  bool outgoing = false,
  bool service = false,
  String? text,
}) =>
    ChatMessage(
        id: id,
        isOutgoing: outgoing,
        isService: service,
        text: text ?? 'hello $id',
        date: id,
      )
      ..translationText = translation
      ..translationLanguageCode = translationLanguage;

AutomaticTranslationLanguageEvidence _evidence(String language) =>
    AutomaticTranslationLanguageEvidence(
      languageCode: language,
      confidence: 1,
      characterCount: 20,
    );

bool _needsTranslation(String language) =>
    language != 'zh' && language != 'und';

void main() {
  group('chat classification (exteraless thresholds)', () {
    ChatTranslationDecision decide(
      List<String> languages, {
      bool translating = false,
    }) => decideChatTranslation(
      evidence: languages.map(_evidence),
      shouldTranslate: _needsTranslation,
      translating: translating,
    );

    test('three foreign messages make the chat translatable', () {
      final decision = decide(['en', 'en', 'fr']);
      expect(decision.translatable, isTrue);
      expect(decision.totalCount, 3);
    });

    test('a chat in the target language is not translatable', () {
      final decision = decide(['zh', 'zh', 'zh']);
      expect(decision.translatable, isFalse);
      expect(decision.notTranslatableCount, 3);
    });

    test('fewer than three checked messages is not enough', () {
      expect(decide(['en']).translatable, isFalse);
      expect(decide(['en', 'fr']).translatable, isFalse);
    });

    test('60% of the classified messages must be translatable', () {
      // 2/4 = 50% — below the threshold even though the unknown ratio is 0.
      expect(decide(['en', 'en', 'zh', 'zh']).translatable, isFalse);
      // 3/5 = 60% — exteraless accepts the boundary.
      expect(decide(['en', 'en', 'en', 'zh', 'zh']).translatable, isTrue);
    });

    test('65% unknown blocks the chat', () {
      // 2 unknown of 3 = 66.7% ≥ 65%.
      expect(decide(['en', 'und', 'und']).translatable, isFalse);
      // 1 unknown of 3 = 33.3% < 65%.
      expect(decide(['en', 'fr', 'und']).translatable, isTrue);
    });

    test('an already translating chat relaxes to two messages', () {
      expect(decide(['en', 'fr'], translating: true).translatable, isTrue);
      expect(decide(['en'], translating: true).translatable, isFalse);
      // Two translatable messages are required, whatever the ratio.
      expect(
        decide(['en', 'zh', 'zh'], translating: true).translatable,
        isFalse,
      );
      // 80% unknown limit instead of 65%.
      expect(
        decide(['en', 'en', 'und', 'und'], translating: true).translatable,
        isTrue,
      );
    });

    test('no evidence never offers translation', () {
      expect(decide(const []).translatable, isFalse);
    });
  });

  group('viewport translation window', () {
    List<ChatMessage> loaded([int count = 60]) => [
      for (var id = 1; id <= count; id++) _message(id),
    ];

    List<int> ids(List<ChatMessage> messages) =>
        messages.map((message) => message.id).toList(growable: false);

    test('only the visible range plus seven ids is translated', () {
      final candidates = automaticTranslationViewportCandidates(
        loaded(),
        visibleMessageIds: {30},
        targetLanguageCode: 'zh-Hans',
      );
      expect(ids(candidates).first, 23);
      expect(ids(candidates).last, 37);
      expect(ids(candidates), isNot(contains(22)));
      expect(ids(candidates), isNot(contains(38)));
    });

    test(
      'a page loaded by scrolling up is translated when it becomes visible',
      () {
        final messages = loaded();
        // While the reader sits at the bottom, the old page is not fetched.
        expect(
          ids(
            automaticTranslationViewportCandidates(
              messages,
              visibleMessageIds: {55, 56},
              targetLanguageCode: 'zh-Hans',
            ),
          ),
          isNot(contains(19)),
        );
        // Scrolling up brings it into the window.
        expect(
          ids(
            automaticTranslationViewportCandidates(
              messages,
              visibleMessageIds: {19},
              targetLanguageCode: 'zh-Hans',
            ),
          ),
          contains(19),
        );
      },
    );

    test(
      'nothing is translated before the transcript publishes a viewport',
      () {
        expect(
          automaticTranslationViewportCandidates(
            loaded(),
            visibleMessageIds: const {},
            targetLanguageCode: 'zh-Hans',
          ),
          isEmpty,
        );
      },
    );

    test('already translated, failed and unsent messages stay out', () {
      final messages = loaded(9);
      messages[4]
        ..translationText = 'translated'
        ..translationLanguageCode = 'zh-Hans';
      messages[5]
        ..translationText = 'old target'
        ..translationLanguageCode = 'en';
      messages[6] = _message(7, outgoing: true);
      messages[7] = _message(8, service: true);
      messages[8] = _message(9, text: '');

      final candidates = automaticTranslationViewportCandidates(
        messages,
        visibleMessageIds: {5},
        targetLanguageCode: 'zh-Hans',
        excludedMessageIds: {3},
      );
      final translatedIds = ids(candidates);
      expect(translatedIds, isNot(contains(3)), reason: 'failed id');
      expect(translatedIds, isNot(contains(5)), reason: 'current target');
      expect(translatedIds, contains(6), reason: 'other target is retried');
      expect(translatedIds, isNot(contains(7)), reason: 'outgoing');
      expect(translatedIds, isNot(contains(8)), reason: 'service');
      expect(translatedIds, isNot(contains(9)), reason: 'no text');
    });

    test('candidates keep transcript order', () {
      final candidates = automaticTranslationViewportCandidates(
        loaded(20),
        visibleMessageIds: {10, 12},
        targetLanguageCode: 'zh-Hans',
      );
      expect(ids(candidates), [
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
      ]);
    });
  });

  test('short messages count as language evidence', () {
    final samples = automaticTranslationLanguageSamples([
      _message(1, text: 'ok'),
      _message(2, text: 'yes'),
    ]);
    expect(samples.map((sample) => sample.messageId), [1, 2]);
  });
}
