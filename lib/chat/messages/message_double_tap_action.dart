//
//  message_double_tap_action.dart
//
//  What a double tap on a message runs, ported from exteraless's "Double tap"
//  chat setting (`NaConfig.doubleTapAction` / `doubleTapActionOut`, consumed by
//  `ChatActivity.hasDoubleTap` / `onDoubleTap`). Incoming and outgoing messages
//  carry their own choice; both default to sending the first quick reaction.
//

import 'package:flutter/widgets.dart' show IconData;

import '../../components/app_icons.dart';
import '../../l10n/app_localizations.dart';

enum MessageDoubleTapAction {
  none(AppStringKeys.doubleTapActionNone, HeroAppIcons.xmark),
  sendReaction(
    AppStringKeys.doubleTapActionSendReaction,
    HeroAppIcons.solidFaceSmile,
  ),
  translate(AppStringKeys.messageActionTranslate, HeroAppIcons.language),
  reply(AppStringKeys.chatInputBarReply, HeroAppIcons.quoteLeft),
  save(AppStringKeys.messageActionFavorite, HeroAppIcons.thumbtack),
  repeat(AppStringKeys.messageActionRepeat, HeroAppIcons.circlePlus),
  edit(AppStringKeys.messageActionEdit, HeroAppIcons.pen),
  delete(AppStringKeys.chatDelete, HeroAppIcons.trash),
  forward(AppStringKeys.messageActionForward, HeroAppIcons.forward),
  saveToPhotos(AppStringKeys.messageActionSaveToPhotos, HeroAppIcons.download);

  const MessageDoubleTapAction(this.label, this._icon);

  final String label;
  final AppIconData _icon;

  IconData get icon => _icon.data;
}
