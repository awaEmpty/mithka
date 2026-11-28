//
//  chat_selection_actions.dart
//
//  The commands behind the chat list's edit-mode bar. exteraless runs ONE
//  action mode for every dialog list, so the main list and the archive page
//  share these implementations instead of each growing its own variant.
//

import 'dart:async';
import 'package:flutter/material.dart';
import '../components/app_anchored_menu.dart';
import '../components/app_confirm_dialog.dart';
import '../components/app_icons.dart';
import '../components/toast.dart';
import '../l10n/app_localizations.dart';
import '../settings/privacy_security/blocked_user_service.dart';
import '../tdlib/td_models.dart';
import 'chat_list_view_model.dart';

/// Whether the block command can act on [chat]: a private conversation with a
/// real user behind it (Saved Messages is a chat with yourself, and groups and
/// channels have no single person to block).
bool chatSelectionCanBlock(ChatSummary chat) {
  if (chat.isSavedMessages) return false;
  final userId = chat.peerUserId;
  if (userId == null || userId <= 0) return false;
  return switch (chat.kind) {
    ChatKind.privateChat || ChatKind.bot || ChatKind.secret => true,
    _ => false,
  };
}

/// exteraless hides its block item unless every selected dialog is blockable.
bool chatSelectionAllBlockable(List<ChatSummary> chats) =>
    chats.isNotEmpty && chats.every(chatSelectionCanBlock);

/// One confirmation, then every selected user goes to the block list.
/// Returns whether the selection was blocked (false when cancelled).
Future<bool> blockChatSelection(
  BuildContext context,
  List<ChatSummary> chats,
) async {
  final userIds = <int>{
    for (final chat in chats)
      if (chatSelectionCanBlock(chat)) chat.peerUserId!,
  };
  if (userIds.isEmpty) return false;
  final confirmed = await showAppConfirmDialog(
    context,
    title: AppStringKeys.chatListBlockUser,
    message: AppStringKeys.chatListBlockUserDescription,
    confirmText: AppStringKeys.chatListBlockUser,
    destructive: true,
  );
  if (!confirmed) return false;
  var blocked = 0;
  for (final userId in userIds) {
    try {
      await BlockedUserService.shared.blockUser(userId);
      blocked++;
    } catch (_) {
      // A batch must not abort on one stubborn user.
    }
  }
  if (context.mounted) {
    showToast(
      context,
      blocked > 0
          ? AppStringKeys.chatListBlockUserDone
          : AppStringKeys.chatDeleteUnavailable,
    );
  }
  return blocked > 0;
}

/// Clears the selected chats' history for this account. The chats stay in the
/// list — this is exteraless's "Clear history", not a delete.
Future<bool> clearChatSelectionHistory(
  BuildContext context,
  ChatListViewModel model,
  List<ChatSummary> chats,
) async {
  if (chats.isEmpty) return false;
  final confirmed = await showAppConfirmDialog(
    context,
    title: AppStringKeys.chatInfoClearHistoryQuestion,
    message: AppStringKeys.chatInfoClearHistoryDescription,
    confirmText: AppStringKeys.chatInfoConfirmClearHistory,
    destructive: true,
  );
  if (!confirmed) return false;
  final cleared = await model.clearHistoryForChats(chats);
  if (context.mounted && cleared == 0) {
    showToast(context, AppStringKeys.chatDeleteUnavailable);
  }
  return cleared > 0;
}

/// Deletes the selection from this account's chat list. Groups and channels
/// leave first, exactly like the single-row delete — the model owns that
/// policy.
Future<bool> deleteChatSelection(
  BuildContext context,
  ChatListViewModel model,
  List<ChatSummary> chats,
) async {
  if (chats.isEmpty) return false;
  final confirmed = await showAppConfirmDialog(
    context,
    title: AppStringKeys.chatListDeleteChatQuestion,
    message: AppStrings.t(AppStringKeys.chatListSelectedCountValue1, {
      'value1': '${chats.length}',
    }),
    confirmText: AppStringKeys.chatDelete.l10n(context),
    destructive: true,
  );
  if (!confirmed) return false;
  await model.deleteChatsForSelection(chats);
  return true;
}

/// Exteraless's "Add to folder": pick one of the account's folders and add
/// every selected chat to its included rules.
Future<void> addChatSelectionToFolder(
  BuildContext context,
  ChatListViewModel model,
  List<ChatSummary> chats, {
  Rect? anchor,
}) async {
  if (chats.isEmpty) return;
  final folders = [
    for (final filter in model.filters)
      if (!filter.isAll && filter.folderId != null) filter,
  ];
  if (folders.isEmpty) return;
  final menuAnchor = anchor ?? Offset.zero & MediaQuery.sizeOf(context);
  await showAppAnchoredMenu(
    context: context,
    anchor: menuAnchor,
    header: AppStrings.t(AppStringKeys.chatListAddToFolder),
    actions: [
      for (final folder in folders)
        AppMenuAction(
          key: 'folder-${folder.folderId}',
          label: folder.title.l10n(context),
          icon: HeroAppIcons.folder,
          onSelected: () => unawaited(
            _addSelectionToFolder(context, model, folder.folderId!, chats),
          ),
        ),
    ],
  );
}

Future<void> _addSelectionToFolder(
  BuildContext context,
  ChatListViewModel model,
  int folderId,
  List<ChatSummary> chats,
) async {
  try {
    await model.addChatsToFolder(folderId, chats);
  } catch (error) {
    if (!context.mounted) return;
    showToast(
      context,
      AppStrings.t(
        AppStringKeys.chatFolderManagementCouldnTUpdateFolderValue1,
        {'value1': error},
      ),
    );
  }
}

/// Removes the selection from the folder currently shown. A chat that only
/// matched by rule becomes an explicit exclusion, so it does not immediately
/// re-enter through that rule.
Future<void> removeChatSelectionFromFolder(
  BuildContext context,
  ChatListViewModel model,
  List<ChatSummary> chats,
) async {
  final folderId = model.selectedFilter.folderId;
  if (folderId == null || chats.isEmpty) return;
  try {
    await model.removeChatsFromFolder(folderId, chats);
  } catch (error) {
    if (!context.mounted) return;
    showToast(
      context,
      AppStrings.t(
        AppStringKeys.chatFolderManagementCouldnTUpdateFolderValue1,
        {'value1': error},
      ),
    );
  }
}

/// exteraless's "Mark as read / Mark as unread" pair: one command whose
/// direction follows the selection — any unread chat makes it a read command,
/// an all-read selection flips it to unread.
void toggleChatSelectionRead(ChatListViewModel model, List<ChatSummary> chats) {
  if (chats.isEmpty) return;
  final anyUnread = chats.any(
    (chat) => chat.unreadCount > 0 || chat.isMarkedUnread,
  );
  if (anyUnread) {
    model.markChatsRead(chats);
  } else {
    model.markChatsUnread(chats);
  }
}
