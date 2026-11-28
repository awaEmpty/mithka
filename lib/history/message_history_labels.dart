//
//  message_history_labels.dart
//
//  Kind-label lookup shared by the history viewer, the revision sheet and the
//  in-chat ghost bubble. Kept out of the widget files so the chat surface can
//  resolve a label without importing the viewer.
//

import 'package:flutter/widgets.dart';
import '../l10n/app_localizations.dart';

/// Localized kind name for a stored kind suffix; unknown kinds keep the
/// generic label instead of leaking the raw key.
String localizedHistoryKindLabel(BuildContext context, String suffix) {
  final key = switch (suffix) {
    'historyKindPhoto' => AppStringKeys.historyKindPhoto,
    'historyKindVideo' => AppStringKeys.historyKindVideo,
    'historyKindVideoNote' => AppStringKeys.historyKindVideoNote,
    'historyKindVoice' => AppStringKeys.historyKindVoice,
    'historyKindAnimation' => AppStringKeys.historyKindAnimation,
    'historyKindSticker' => AppStringKeys.historyKindSticker,
    'historyKindDocument' => AppStringKeys.historyKindDocument,
    'historyKindAudio' => AppStringKeys.historyKindAudio,
    'historyKindPoll' => AppStringKeys.historyKindPoll,
    'historyKindLocation' => AppStringKeys.historyKindLocation,
    'historyKindContact' => AppStringKeys.historyKindContact,
    'historyKindDice' => AppStringKeys.historyKindDice,
    _ => AppStringKeys.historyKindUnknown,
  };
  return AppStrings.t(key).isEmpty ? suffix : key.l10n(context);
}
