import '../../settings/ai_translation/translation_controller.dart';
import '../../tdlib/td_models.dart';

String automaticTranslationSourceText(ChatMessage message) {
  if (!_hasTranslatableText(message)) return '';
  final parts = [
    message.text,
    message.linkPreview?.title ?? '',
    message.linkPreview?.description ?? '',
  ].where((part) => part.trim().isNotEmpty);
  return parts.join('\n');
}

/// A Gram transfer's text is its preview line ("[Transfer] 1.5 GRAM"), not
/// anything its sender wrote, so it is never translated or sampled.
bool _hasTranslatableText(ChatMessage message) => message.gramTransfer == null;

const _languageDetectionIgnoredEntityTypes = <String>{
  'textEntityTypePre',
  'textEntityTypePreCode',
  'textEntityTypeCode',
  'textEntityTypeUrl',
  'textEntityTypeEmailAddress',
  'textEntityTypeMention',
  'textEntityTypeHashtag',
  'textEntityTypeBotCommand',
};

String automaticTranslationLanguageText(ChatMessage message) {
  if (!_hasTranslatableText(message)) return '';
  var text = message.text.length > 256
      ? message.text.substring(0, 256)
      : message.text;
  final ranges =
      message.textEntities
          .where(
            (entity) =>
                _languageDetectionIgnoredEntityTypes.contains(entity.type) &&
                entity.offset >= 0 &&
                entity.offset < text.length,
          )
          .map(
            (entity) => (
              start: entity.offset,
              end: entity.end.clamp(entity.offset, text.length),
            ),
          )
          .where((range) => range.end > range.start)
          .toList()
        ..sort((a, b) => b.start.compareTo(a.start));
  for (final range in ranges) {
    text = text.replaceRange(range.start, range.end, '');
  }
  return text.trim();
}

/// One message the language classifier may look at. The message id is kept so
/// a detection result can be reused instead of asking the platform again (the
/// classifier runs on every transcript and settings change).
class AutomaticTranslationLanguageSample {
  const AutomaticTranslationLanguageSample({
    required this.messageId,
    required this.text,
  });

  final int messageId;
  final String text;
}

/// Messages that can be fed to language identification, oldest first.
///
/// Every message with text counts — including short ones, exactly like
/// exteraless: a detector that answers "unknown" for a short message is
/// evidence too, and excluding it would make a chat of one-word replies look
/// translatable forever.
List<AutomaticTranslationLanguageSample> automaticTranslationLanguageSamples(
  List<ChatMessage> messages, {
  int maximumMessages = 16,
  int minimumMessageLength = 1,
}) {
  final samples = <AutomaticTranslationLanguageSample>[];
  for (final message in messages.reversed) {
    if (samples.length >= maximumMessages) break;
    if (message.id <= 0 || message.isOutgoing || message.isService) continue;
    final source = automaticTranslationLanguageText(message);
    if (source.length < minimumMessageLength) continue;
    samples.add(
      AutomaticTranslationLanguageSample(messageId: message.id, text: source),
    );
  }
  return samples.reversed.toList(growable: false);
}

class AutomaticTranslationLanguageEvidence {
  const AutomaticTranslationLanguageEvidence({
    required this.languageCode,
    required this.confidence,
    required this.characterCount,
  });

  /// The normalized language code, `und` when identification failed.
  final String languageCode;
  final double confidence;
  final int characterCount;
}

/// The per-message language evidence of one chat, computed the way
/// exteraless's `TranslateController.checkDialogTranslatable` counts it.
class ChatTranslationDecision {
  const ChatTranslationDecision({
    required this.translatable,
    required this.translatableCount,
    required this.unknownCount,
    required this.notTranslatableCount,
  });

  final bool translatable;
  final int translatableCount;
  final int unknownCount;
  final int notTranslatableCount;

  int get totalCount => translatableCount + unknownCount + notTranslatableCount;
}

/// exteraless's dialog-classification thresholds (`TranslateController`).
///
/// A chat is offered "translate this chat" when at least three of its
/// messages were checked, at least 60% of the classified ones are in a
/// language the user translates, and fewer than 65% of all checked messages
/// were undetectable. A chat that is already translating relaxes to two
/// messages / two translatable / under 80% unknown.
abstract final class ChatTranslationThresholds {
  static const int requiredMessages = 3;
  static const int requiredMessagesWhileTranslating = 2;
  static const double requiredTranslatableRatio = .60;
  static const int minimumTranslatableWhileTranslating = 2;
  static const double maximumUnknownRatio = .65;
  static const double maximumUnknownRatioWhileTranslating = .80;
}

/// exteraless's `TranslatableDecision`, evaluated over [evidence].
///
/// [shouldTranslate] is the restricted-language check: a message whose
/// language is the target language (or a language the user told the app not
/// to translate) counts as certainly not translatable. A detection that
/// failed counts as unknown, never as translatable.
ChatTranslationDecision decideChatTranslation({
  required Iterable<AutomaticTranslationLanguageEvidence> evidence,
  required bool Function(String languageCode) shouldTranslate,
  required bool translating,
}) {
  var translatableCount = 0;
  var unknownCount = 0;
  var notTranslatableCount = 0;
  for (final item in evidence) {
    final language = TranslationController.normalizeLanguageCode(
      item.languageCode,
    );
    if (language == null || language == 'und') {
      unknownCount++;
    } else if (shouldTranslate(language)) {
      translatableCount++;
    } else {
      notTranslatableCount++;
    }
  }
  final classified = translatableCount + notTranslatableCount;
  final total = classified + unknownCount;
  final requiredMessages = translating
      ? ChatTranslationThresholds.requiredMessagesWhileTranslating
      : ChatTranslationThresholds.requiredMessages;
  final translatableEnough = translating
      ? translatableCount >=
            ChatTranslationThresholds.minimumTranslatableWhileTranslating
      : classified > 0 &&
            translatableCount / classified >=
                ChatTranslationThresholds.requiredTranslatableRatio;
  final unknownLimit = translating
      ? ChatTranslationThresholds.maximumUnknownRatioWhileTranslating
      : ChatTranslationThresholds.maximumUnknownRatio;
  final unknownLowEnough = total > 0 && unknownCount / total < unknownLimit;
  return ChatTranslationDecision(
    translatable:
        total >= requiredMessages && translatableEnough && unknownLowEnough,
    translatableCount: translatableCount,
    unknownCount: unknownCount,
    notTranslatableCount: notTranslatableCount,
  );
}

/// How many ids on each side of the visible range exteraless also translates
/// (`mid >= minId - 7 && mid <= maxId + 7`).
const int automaticTranslationViewportNeighborDistance = 7;

/// The messages an automatic translation pass may translate.
///
/// exteraless translates only what is near the transcript's viewport: every
/// message within seven ids of the visible range, and nothing else. Scrolling
/// publishes a new viewport, so the next page is translated when it is about
/// to be read instead of walking the whole loaded history in the background.
/// [messages] must be in transcript order; the returned list keeps that
/// order.
List<ChatMessage> automaticTranslationViewportCandidates(
  List<ChatMessage> messages, {
  required Set<int> visibleMessageIds,
  required String targetLanguageCode,
  Set<int> excludedMessageIds = const {},
  int neighborDistance = automaticTranslationViewportNeighborDistance,
}) {
  if (visibleMessageIds.isEmpty) return const [];
  var minId = 1 << 62;
  var maxId = -(1 << 62);
  for (final id in visibleMessageIds) {
    if (id < minId) minId = id;
    if (id > maxId) maxId = id;
  }
  final window = <ChatMessage>[
    for (final message in messages)
      if (message.id >= minId - neighborDistance &&
          message.id <= maxId + neighborDistance)
        message,
  ];
  final target = TranslationController.normalizeLanguageCode(
    targetLanguageCode,
  );
  // Transcript order, like exteraless's `messages` walk: a page is queued
  // oldest first. The viewport is what bounds the work, not a newest-N cut.
  return [
    for (final message in window)
      if (message.id > 0 &&
          !message.isOutgoing &&
          !message.isService &&
          !message.isTranslating &&
          !excludedMessageIds.contains(message.id) &&
          automaticTranslationSourceText(message).trim().isNotEmpty &&
          !((message.translationText?.trim().isNotEmpty ?? false) &&
              TranslationController.normalizeLanguageCode(
                    message.translationLanguageCode,
                  ) ==
                  target))
        message,
  ];
}

String? dominantAutomaticTranslationLanguage(
  Iterable<AutomaticTranslationLanguageEvidence> evidence,
) {
  final weights = <String, double>{};
  for (final item in evidence) {
    final language = TranslationController.normalizeLanguageCode(
      item.languageCode,
    );
    if (language == null ||
        language == 'und' ||
        item.confidence <= 0 ||
        item.characterCount <= 0) {
      continue;
    }
    weights.update(
      language,
      (weight) => weight + item.characterCount * item.confidence,
      ifAbsent: () => item.characterCount * item.confidence,
    );
  }
  if (weights.isEmpty) return null;
  return weights.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}
