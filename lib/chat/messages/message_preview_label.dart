import '../../l10n/app_localizations.dart';
import '../../tdlib/td_models.dart';

/// The one-line label a media message shows where only text fits (the pinned
/// bar, search fallbacks). A photo/video/GIF/file/voice/music message is not
/// a generic “[message]”: the label names the kind, using the same localized
/// placeholders the composer and media screens already use.
String messagePreviewLabel(ChatMessage message) {
  final type = message.contentType ?? '';
  switch (type) {
    case 'messageAnimation':
      return AppStrings.t(AppStringKeys.tdMessageGif);
    case 'messageVideo':
      return AppStrings.t(AppStringKeys.chatVideoPlaceholder);
    case 'messageVideoNote':
      return AppStrings.t(AppStringKeys.tdMessageVideoMessage);
    case 'messagePhoto':
      return AppStrings.t(AppStringKeys.composerImagePreview);
    case 'messageSticker':
      return AppStrings.t(AppStringKeys.tdMessageStickerPreview);
    case 'messageAnimatedEmoji':
      return AppStrings.t(AppStringKeys.composerAnimatedEmojiPreview);
    case 'messageVoiceNote':
      return AppStrings.t(AppStringKeys.composerVoicePreview);
    case 'messageAudio':
      return AppStrings.t(AppStringKeys.tdMessageMusic);
    case 'messageDocument':
      return AppStrings.t(AppStringKeys.channelsFileAttachment);
    case 'messagePoll':
      return AppStrings.t(AppStringKeys.tdMessagePoll);
    case 'messageLocation':
    case 'messageVenue':
      return AppStrings.t(AppStringKeys.composerLocationPreview);
    case 'messageContact':
      return AppStrings.t(AppStringKeys.tdMessageContactCard);
    case 'messageDice':
      return AppStrings.t(AppStringKeys.tdMessageDice);
    case 'messageGift':
      return AppStrings.t(AppStringKeys.tdMessageGift);
    case 'messageStory':
      return AppStrings.t(AppStringKeys.tdMessageForwardedStory);
    case 'messageChecklist':
      return AppStrings.t(AppStringKeys.tdMessageChecklist);
    case 'messageGame':
      return AppStrings.t(AppStringKeys.tdMessageGame);
    case 'messageGiveaway':
      return AppStrings.t(AppStringKeys.tdMessageGiveaway);
  }
  // Older cached messages may carry a media field without a content type.
  if (message.music != null) {
    return AppStrings.t(AppStringKeys.tdMessageMusic);
  }
  if (message.voice != null) {
    return AppStrings.t(AppStringKeys.composerVoicePreview);
  }
  if (message.video != null) {
    return AppStrings.t(AppStringKeys.chatVideoPlaceholder);
  }
  if (message.document != null) {
    return AppStrings.t(AppStringKeys.channelsFileAttachment);
  }
  if (message.image != null) {
    return AppStrings.t(AppStringKeys.composerImagePreview);
  }
  if (message.poll != null) {
    return AppStrings.t(AppStringKeys.tdMessagePoll);
  }
  if (message.location != null) {
    return AppStrings.t(AppStringKeys.composerLocationPreview);
  }
  if (message.contact != null) {
    return AppStrings.t(AppStringKeys.tdMessageContactCard);
  }
  if (message.stickerFileId != null) {
    return AppStrings.t(AppStringKeys.tdMessageStickerPreview);
  }
  if (message.isAnimatedEmoji) {
    return AppStrings.t(AppStringKeys.composerAnimatedEmojiPreview);
  }
  if (message.gift != null) {
    return AppStrings.t(AppStringKeys.tdMessageGift);
  }
  return AppStrings.t(AppStringKeys.chatSearchMessageResultLabel);
}
