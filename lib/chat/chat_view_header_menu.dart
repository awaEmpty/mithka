//  chat_view_header_menu.dart
//
//  The header menu button and the chat command column it opens.
//  Fork-only: upstream keeps per-action header buttons instead.
//

part of 'chat_view.dart';

/// The chat's menu button — the header's `☰`, exteraless's `headerItem`.
///
/// It used to be the details page's door; the title took that job so this one
/// could carry every chat command in one predictable place. The glyph is the
/// three-bar action-bar menu, exactly the control exteraless puts at the far
/// right of a chat header.
class _ChatHeaderMenuButton extends StatelessWidget {
  const _ChatHeaderMenuButton({required this.onPressed});

  /// Receives the button's global rect so the menu hangs off it.
  final ValueChanged<Rect> onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppInteractiveSurface(
      key: const ValueKey('chatHeaderMenu'),
      semanticLabel: AppStringKeys.chatMenu.l10n(context),
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        onPressed(box.localToGlobal(Offset.zero) & box.size);
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: SizedBox(
        width: math.max(44, AppMetric.hitTarget),
        height: math.max(44, AppMetric.hitTarget),
        child: Center(
          child: AppIcon(
            HeroAppIcons.bars,
            size: AppIconSize.nav,
            color: c.textPrimary,
          ),
        ),
      ),
    );
  }
}

extension _ChatViewHeaderMenu on _ChatViewState {
  /// The chat's overflow button — exteraless's `⋮` action-bar item — and the
  /// column it opens.
  ///
  /// The column mirrors exteraless's `chat_menu_options` block for block:
  /// search and the pinned-message browser on top, then the chat commands
  /// (mute with its duration chooser, translation, linked chat, direct
  /// messages, calls, auto-delete), then management for an admin, then the
  /// transcript jumps (to the beginning, to a typed message id), and finally
  /// the destructive tail. Search leads because it used to hold its own
  /// header glyph; a menu that pushes the most-used command to the bottom
  /// reads backwards. Theme and wallpaper stay in the details page — the
  /// header column keeps to what acts on the conversation itself.

  /// The menu exists only when the chat offers at least one command: a join
  /// screen with nothing to act on shows no button.
  bool get _showsChatMenu => _chatHeaderMenuActions().isNotEmpty;

  /// Where the header's details control used to go: the side panel on a phone
  /// layout, the full info page on a wide one. The title tap uses the same
  /// path, so both platforms keep their own presentation.
  void _openChatDetails() {
    if (widget.onOpenFullInfo != null) {
      _handleFullInfoPressed();
      return;
    }
    _handleInfoPressed();
  }

  /// Opens the topic list the way the chat title's chevron promises: a
  /// sidebar-placement shell whose list the user dismissed gets it back;
  /// every other shell picks from the sheet.
  void _openTopicList() {
    final host = _topicListOverlaid ? _shellTopicListHost : null;
    if (host != null && host.listHidden) {
      host.showList();
      return;
    }
    unawaited(_showTopicSelector());
  }

  /// exteraless offers the chat-level translate command only where the
  /// classifier found the chat worth translating; a chat already in the
  /// target language, or one whose language is still unknown, carries no
  /// Translate entry (turning an active translation off always stays
  /// reachable). The entry also stays after the suggestion bar is dismissed —
  /// exteraless moves the command into the ⋮ menu when its bar is hidden, so
  /// hiding the bar never removes the only way back.
  bool get _canToggleChatTranslation =>
      _hasAvailableTranslationOption &&
      _chatTranslationSupported &&
      _translation.translateChats &&
      _hasIncomingTranslatableMessages &&
      (_automaticTranslationEnabled || _chatNeedsTranslation);

  String get _chatDisplayTitle =>
      _vm.peerTitle.isEmpty ? widget.title : _vm.peerTitle;

  Future<void> _showChatHeaderMenu(Rect anchor) async {
    final actions = _chatHeaderMenuActions();
    if (actions.isEmpty) return;
    await showAppAnchoredMenu(
      context: context,
      anchor: anchor,
      actions: actions,
      // The column belongs to the button it hangs from, the way exteraless
      // anchors an action-bar submenu.
      gap: AppSpacing.xs,
      style: AppAnchoredMenuStyle.header,
    );
  }

  /// The commands this chat offers from its header menu, in the order the
  /// column draws them.
  List<AppMenuAction> _chatHeaderMenuActions() {
    final topic = _topicById(widget.forumTopicId);
    final canCallPeer =
        !_vm.isGroup &&
        !_vm.peerIsBot &&
        !_vm.isSavedMessages &&
        !_vm.isSecretChat &&
        _vm.canCallPeer;
    final canVideoCallPeer = canCallPeer && _vm.canVideoCallPeer;
    final canChangeAutoDelete = !_vm.isGroup && !_vm.isSavedMessages;
    final canManageGroup = _vm.isGroup && _vm.canManageGroup;
    final canLeave =
        _vm.isGroup &&
        _vm.isMember &&
        !_vm.isChatCreator &&
        !_vm.isSavedMessages;
    final canDeleteChat = !_vm.isGroup && !_vm.isSavedMessages;
    final canCloseTopic =
        topic != null && !topic.isClosed && _vm.canCloseTopic(topic);
    final callAvailabilityKnown = _vm.canCallPeer || _vm.canVideoCallPeer;
    // A chat the user has not joined has no appearance of its own to set and
    // no history to clear: its menu carries only the commands that read the
    // chat (search, pinned, translation), never the ones that change it.
    final inChat = _vm.isMember || !_vm.isGroup;
    return [
      if (_canSearchMessages)
        AppMenuAction(
          key: 'search',
          label: AppStrings.t(AppStringKeys.chatSearchInThisChat),
          icon: HeroAppIcons.magnifyingGlass,
          onSelected: _openSearch,
        ),
      if (_vm.pinnedMessage != null)
        AppMenuAction(
          key: 'pinned-messages',
          label: AppStrings.t(AppStringKeys.chatInfoPinnedHighlights),
          icon: HeroAppIcons.pin,
          onSelected: () => unawaited(_openPinnedMessages()),
        ),
      // Saved messages and a secret chat have nothing to silence; a chat the
      // user has not joined has no subscription to mute either.
      if (_vm.isMember && !_vm.isSecretChat && !_vm.isSavedMessages)
        AppMenuAction(
          key: 'mute',
          label: AppStrings.t(
            _vm.isMuted ? AppStringKeys.chatUnmute : AppStringKeys.chatMute,
          ),
          icon: _vm.isMuted ? HeroAppIcons.bell : HeroAppIcons.bellSlash,
          sectionStart: true,
          // A muted chat unmutes on the tap, like exteraless; a live one opens
          // the durations as a submenu of this same card, so the command and
          // its lengths stay one control instead of a sheet on top of a menu.
          onSelected: _vm.isMuted ? () => unawaited(_vm.setMuteFor(0)) : null,
          children: _vm.isMuted
              ? null
              : [
                  for (final option in const [
                    (AppStringKeys.chatMuteFor1Hour, 60 * 60),
                    (AppStringKeys.chatMuteFor8Hours, 8 * 60 * 60),
                    (AppStringKeys.chatMuteFor2Days, 2 * 24 * 60 * 60),
                    (AppStringKeys.chatMuteForever, 2147483647),
                  ])
                    AppMenuAction(
                      key: 'mute-${option.$2}',
                      label: AppStrings.t(option.$1),
                      onSelected: () => unawaited(_vm.setMuteFor(option.$2)),
                    ),
                ],
        ),
      if (_canToggleChatTranslation)
        AppMenuAction(
          key: 'translate',
          label: _automaticTranslationEnabled
              ? AppStrings.t(AppStringKeys.chatTranslationShowOriginal)
              : AppStrings.t(AppStringKeys.chatTranslationTranslateTo, {
                  'value1': _translation.targetLanguageLabel.l10n(context),
                }),
          icon: HeroAppIcons.language,
          onSelected: _toggleAutomaticTranslation,
        ),
      if (_vm.linkedDiscussionChatId != 0)
        AppMenuAction(
          key: 'linked-chat',
          label: AppStrings.t(
            _vm.isChannel
                ? AppStringKeys.groupAdminDiscussionGroup
                : AppStringKeys.chatLinkedChannel,
          ),
          icon: HeroAppIcons.users,
          onSelected: () =>
              unawaited(_openChannelLinkedChat(_vm.linkedDiscussionChatId)),
        ),
      if (_vm.hasDirectMessagesGroup && !_vm.isDirectMessagesGroup)
        AppMenuAction(
          key: 'direct-messages',
          label: AppStrings.t(AppStringKeys.channelDirectMessages),
          icon: HeroAppIcons.solidMessage,
          onSelected: () =>
              unawaited(_openChannelLinkedChat(_vm.directMessagesChatId)),
        ),
      if (callAvailabilityKnown &&
          canCallPeer &&
          !isDesktopTargetPlatform(Theme.of(context).platform))
        AppMenuAction(
          key: 'call',
          label: AppStrings.t(AppStringKeys.composerVoiceCall),
          icon: HeroAppIcons.phone,
          onSelected: () => unawaited(_startCall(false)),
        ),
      if (callAvailabilityKnown &&
          canVideoCallPeer &&
          !isDesktopTargetPlatform(Theme.of(context).platform))
        AppMenuAction(
          key: 'video-call',
          label: AppStrings.t(AppStringKeys.composerVideoCall),
          icon: HeroAppIcons.video,
          onSelected: () => unawaited(_startCall(true)),
        ),
      if (canChangeAutoDelete)
        AppMenuAction(
          key: 'auto-delete',
          label: AppStrings.t(AppStringKeys.chatInfoAutoDeleteMessages),
          icon: HeroAppIcons.clock,
          // Same split as mute: the lengths are a page of this card, not a
          // sheet over it.
          children: [
            for (final option in const [
              (AppStringKeys.chatInfoAutoDeleteOff, 0),
              (AppStringKeys.chatInfoAutoDeleteOneDay, 86400),
              (AppStringKeys.chatInfoAutoDeleteSevenDays, 604800),
              (AppStringKeys.chatInfoAutoDeleteOneMonth, 2592000),
            ])
              AppMenuAction(
                key: 'auto-delete-${option.$2}',
                label: AppStrings.t(option.$1),
                onSelected: () =>
                    unawaited(_vm.setMessageAutoDeleteTime(option.$2)),
              ),
          ],
        ),
      if (canManageGroup)
        AppMenuAction(
          key: 'manage',
          label: AppStrings.t(AppStringKeys.chatInfoManageGroup),
          icon: HeroAppIcons.users,
          sectionStart: true,
          onSelected: _openGroupManagement,
        ),
      if (_vm.hasOlderHistory)
        AppMenuAction(
          key: 'to-beginning',
          label: AppStrings.t(AppStringKeys.chatToBeginning),
          icon: HeroAppIcons.arrowUp,
          sectionStart: true,
          onSelected: () => unawaited(_jumpToBeginning()),
        ),
      if (inChat)
        AppMenuAction(
          key: 'go-to-message',
          label: AppStrings.t(AppStringKeys.chatGoToMessage),
          icon: HeroAppIcons.arrowRight,
          onSelected: () => unawaited(_goToMessageFromMenu()),
        ),
      if (inChat && allowTelegramTosViolations)
        AppMenuAction(
          key: 'kept-messages',
          label: AppStrings.t(AppStringKeys.historyTitle),
          icon: HeroAppIcons.archiveBox,
          onSelected: _openKeptMessages,
        ),
      if (inChat && _vm.canClearHistory)
        AppMenuAction(
          key: 'clear-history',
          label: AppStrings.t(AppStringKeys.chatInfoClearHistory),
          icon: HeroAppIcons.trash,
          destructive: true,
          sectionStart: true,
          onSelected: () => unawaited(_clearHistoryFromMenu()),
        ),
      if (canLeave)
        AppMenuAction(
          key: 'leave',
          label: AppStrings.t(
            _vm.isChannel
                ? AppStringKeys.topicChatLeaveChannel
                : AppStringKeys.chatInfoLeaveGroup,
          ),
          icon: HeroAppIcons.arrowRight,
          destructive: true,
          onSelected: () => unawaited(_leaveFromMenu()),
        ),
      if (canDeleteChat)
        AppMenuAction(
          key: 'delete-chat',
          label: AppStrings.t(AppStringKeys.chatDelete),
          icon: HeroAppIcons.trash,
          destructive: true,
          onSelected: () => unawaited(_deleteChatFromMenu()),
        ),
      if (canCloseTopic)
        AppMenuAction(
          key: 'close-topic',
          label: AppStrings.t(AppStringKeys.topicChatCloseTopic),
          icon: HeroAppIcons.lock,
          sectionStart: true,
          onSelected: () => unawaited(_toggleTopicClosed(topic)),
        ),
    ];
  }

  /// Mute with exteraless's durations. An already-muted chat unmutes on the
  /// tap; otherwise the sheet asks until when.
  /// The auto-delete chooser, same options and request as the details page.
  void _openGroupManagement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GroupManagementView(
          chatId: _vm.chatId,
          title: _chatDisplayTitle,
          isChannel: _vm.isChannel,
        ),
      ),
    );
  }

  void _openKeptMessages() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MessageHistoryView(chatId: _vm.chatId),
      ),
    );
  }

  /// Opens the chat's pinned-message browser — the same page the details view
  /// links to.
  Future<void> _openPinnedMessages() async {
    // The reference client opens MODE_PINNED inside the chat: a tap on a
    // pinned bubble closes the list and scrolls the open transcript there.
    // The page returns the message id, or [PinnedMessagesExit.hide] when the
    // bottom bar's "Hide pinned messages" was used.
    final result = await Navigator.of(context).push<Object>(
      AppPageRoute<Object>(
        pageBuilder: (_, _, _) => PinnedMessagesView(
          chatId: _vm.chatId,
          title: _chatDisplayTitle,
          onReply: _beginSwipeReply,
          onForward: (message) => unawaited(_forwardMessage(message)),
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result is int) {
      await _scrollToMessage(result, forceAlignment: true);
      return;
    }
    if (result == PinnedMessagesExit.hide) _vm.dismissPinned();
  }

  /// exteraless's "to the beginning": the chat's very first message. TDLib
  /// keeps message ids positive per chat, so id 1 is the oldest one, and the
  /// transcript loads the page around it if it is not in memory.
  ///
  /// Inside a topic the transcript only holds that topic's messages, so the
  /// chat's id 1 is not reachable from it — a topic's id *is* its first
  /// message's id (1 for the General topic), which is the oldest row the
  /// topic's history can return.
  Future<void> _jumpToBeginning() {
    final topicId = widget.forumTopicId;
    final target = topicId == null || topicId <= 0 ? 1 : topicId;
    return _scrollToMessage(target, forceAlignment: true);
  }

  /// exteraless's "Go To": prompt for a message id and land on it. The
  /// transcript pages around the id, so it works for messages it has not
  /// loaded yet; an id that does not exist simply navigates nowhere.
  Future<void> _goToMessageFromMenu() async {
    final input = await showAppTextEntryDialog(
      context,
      title: AppStrings.t(AppStringKeys.chatGoToMessage),
      actionLabel: AppStrings.t(AppStringKeys.confirmOk),
      hint: AppStrings.t(AppStringKeys.chatGoToMessageHint),
      keyboardType: TextInputType.number,
      allowEmpty: false,
    );
    if (!mounted || input == null) return;
    final messageId = int.tryParse(input.trim());
    if (messageId == null || messageId <= 0) return;
    await _scrollToMessage(messageId, forceAlignment: true);
  }

  /// Clears this chat's history for this account and leaves the chat on
  /// screen, emptied — the details page's flow, reachable from the menu.
  Future<void> _clearHistoryFromMenu() async {
    final confirmed = await showTwoStepClearHistoryDialog(
      context,
      chatTitle: _chatDisplayTitle,
    );
    if (!mounted || !confirmed) return;
    try {
      await clearChatHistoryForSelf(
        chatId: _vm.chatId,
        query: TdClient.shared.query,
      );
      TdClient.shared.emitLocalUpdate({
        '@type': 'mithkaChatHistoryCleared',
        'chat_id': _vm.chatId,
      });
    } catch (error) {
      if (!mounted) return;
      showToast(context, _chatRemovalErrorText(error));
    }
  }

  /// Leaves a group or channel through the same two-stage gate and helpers the
  /// details page uses, then closes the transcript like exteraless does.
  Future<void> _leaveFromMenu() async {
    final action = _vm.isChannel
        ? AppStringKeys.topicChatLeaveChannel
        : AppStringKeys.chatInfoLeaveGroup;
    final impact = AppStrings.t(AppStringKeys.chatLeaveAndDeleteDescription, {
      'value1': _chatDisplayTitle,
    });
    final confirmed = await showTwoStepDestructiveConfirmation(
      context,
      firstTitle: AppStrings.t(action),
      firstMessage: impact,
      firstConfirmText: AppStringKeys.confirmContinue,
      finalTitle: AppStrings.t(AppStringKeys.chatDeleteFinalQuestion, {
        'value1': _chatDisplayTitle,
      }),
      finalMessage:
          '$impact\n\n${AppStringKeys.chatDeleteFinalWarning.l10n(context)}',
      finalConfirmText: AppStrings.t(action),
    );
    if (!mounted || !confirmed) return;
    try {
      await leaveChatAndRemoveFromList(
        chatId: _vm.chatId,
        query: TdClient.shared.query,
        onLeft: () =>
            TdClient.shared.emitLocalUpdate(chatLeftLocalUpdate(_vm.chatId)),
      );
      if (mounted) _handleBack();
    } catch (error) {
      if (!mounted) return;
      showToast(context, _chatRemovalErrorText(error));
    }
  }

  /// Deletes a private chat: the same scope dialog and requests the chat list
  /// uses, then closes the transcript.
  Future<void> _deleteChatFromMenu() async {
    ChatDeleteCapabilities capabilities;
    try {
      final chat = await TdClient.shared.query({
        '@type': 'getChat',
        'chat_id': _vm.chatId,
      });
      capabilities = chatDeleteCapabilities(chat);
    } catch (_) {
      capabilities = const ChatDeleteCapabilities.none();
    }
    if (!mounted) return;
    if (!capabilities.canDelete) {
      showToast(context, AppStringKeys.chatDeleteUnavailable);
      return;
    }
    final scope = await showTwoStepChatDeleteDialog(
      context,
      title: AppStringKeys.chatListDeleteChatQuestion,
      selfOnlyDescription: AppStringKeys.chatInfoClearHistoryDescription.l10n(
        context,
      ),
      capabilities: capabilities,
      isGroupOrChannel: false,
      isSavedMessages: false,
      chatTitle: _chatDisplayTitle,
      selfConfirmText: AppStringKeys.chatDelete,
    );
    if (!mounted || scope == null) return;
    try {
      if (scope == ChatDeleteScope.self) {
        await TdClient.shared.query(
          deleteChatHistoryRequest(
            chatId: _vm.chatId,
            scope: ChatDeleteScope.self,
          ),
        );
      } else {
        await TdClient.shared.query({
          '@type': 'deleteChat',
          'chat_id': _vm.chatId,
        });
      }
      TdClient.shared.emitLocalUpdate(chatLeftLocalUpdate(_vm.chatId));
      if (mounted) _handleBack();
    } catch (error) {
      if (!mounted) return;
      showToast(context, _chatRemovalErrorText(error));
    }
  }

  String _chatRemovalErrorText(Object error) => switch (error) {
    ChatRemovalUnavailable() => AppStrings.t(
      AppStringKeys.chatDeleteUnavailable,
    ),
    ChatLeaveHistoryCleanupFailed() => AppStrings.t(
      _vm.isChannel
          ? AppStringKeys.chatLeaveHistoryCleanupFailedChannel
          : AppStringKeys.chatLeaveHistoryCleanupFailed,
    ),
    TdError() => error.message,
    _ => error.toString(),
  };
}
