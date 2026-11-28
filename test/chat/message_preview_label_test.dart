import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/messages/message_preview_label.dart';
import 'package:mithka/tdlib/td_models.dart';

import '../support/l10n_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = L10nFixtures.load()..install();

  ChatMessage message(String type, {MessageMusic? music}) => ChatMessage(
    id: 1,
    isOutgoing: false,
    text: '',
    date: 1,
    contentType: type,
    music: music,
  );

  test('media messages name their kind instead of [message]', () {
    final labels = {
      'messagePhoto': fixtures.en.strings['composerImagePreview'],
      'messageVideo': fixtures.en.strings['chatVideoPlaceholder'],
      'messageAnimation': fixtures.en.strings['tdMessageGif'],
      'messageVideoNote': fixtures.en.strings['tdMessageVideoMessage'],
      'messageVoiceNote': fixtures.en.strings['composerVoicePreview'],
      'messageAudio': fixtures.en.strings['tdMessageMusic'],
      'messageDocument': fixtures.en.strings['channelsFileAttachment'],
      'messageSticker': fixtures.en.strings['tdMessageStickerPreview'],
      'messagePoll': fixtures.en.strings['tdMessagePoll'],
      'messageLocation': fixtures.en.strings['composerLocationPreview'],
      'messageContact': fixtures.en.strings['tdMessageContactCard'],
    };
    for (final entry in labels.entries) {
      expect(
        messagePreviewLabel(message(entry.key)),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('a music message uses the music label without a content type', () {
    final music = MessageMusic(title: 'Song');
    expect(
      messagePreviewLabel(message('', music: music)),
      fixtures.en.strings['tdMessageMusic'],
    );
  });

  test('plain text keeps the generic message label', () {
    expect(
      messagePreviewLabel(message('messageText')),
      fixtures.en.strings['chatSearchMessageResultLabel'],
    );
  });
}
