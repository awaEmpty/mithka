import 'auto_translate_policy.dart';

/// Process-wide cache of per-message language detections.
///
/// The chat translatability classifier asks the platform to identify the
/// languages of a chat's newest messages. That answer is a property of the
/// message (not of the translation target), so it must survive a topic
/// switch, a settings change and every transcript refresh. exteraless keeps
/// the same fact on the message's custom params; a bounded in-memory map is
/// enough here because a detection that is lost is simply asked again.
class ChatTranslationLanguageCache {
  ChatTranslationLanguageCache._();

  static final ChatTranslationLanguageCache shared =
      ChatTranslationLanguageCache._();

  static const int _maximumEntriesPerChat = 64;
  static const int _maximumChats = 32;

  final Map<
    ({int accountSlot, int chatId}),
    Map<int, AutomaticTranslationLanguageEvidence>
  >
  _byChat = {};

  AutomaticTranslationLanguageEvidence? read({
    required int accountSlot,
    required int chatId,
    required int messageId,
  }) => _byChat[(accountSlot: accountSlot, chatId: chatId)]?[messageId];

  void write({
    required int accountSlot,
    required int chatId,
    required int messageId,
    required AutomaticTranslationLanguageEvidence evidence,
  }) {
    final samples = _byChat.putIfAbsent((
      accountSlot: accountSlot,
      chatId: chatId,
    ), () => <int, AutomaticTranslationLanguageEvidence>{});
    if (_byChat.length > _maximumChats) {
      _byChat.remove(_byChat.keys.first);
    }
    samples[messageId] = evidence;
    if (samples.length <= _maximumEntriesPerChat) return;
    final ids = samples.keys.toList()..sort();
    for (final id in ids.take(samples.length - _maximumEntriesPerChat)) {
      samples.remove(id);
    }
  }

  /// Tests only.
  void resetForTesting() => _byChat.clear();
}
