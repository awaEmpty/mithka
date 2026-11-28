//
//  android_share_intake.dart
//
//  What happens after Android hands Mithka a share: pick the destination, then
//  prepare and send the payload.
//
//  The order matters and it is the reference client's. exteraless's
//  `LaunchActivity` parses the SEND intent and immediately opens
//  `DialogsActivity` with the shared entries attached; the provider URIs are
//  only read for the chat the user picked. A share therefore always puts a
//  surface on screen — a slow provider, an unreadable URI or a cancelled copy
//  can no longer look like "sharing did nothing".
//

import 'dart:async';

import 'package:flutter/widgets.dart';
import '../platform/android_share_intent.dart';
import '../tdlib/td_models.dart' show ChatSummary;

/// Opens the destination picker and resolves to the chosen chat, or null when
/// the user backed out.
typedef AndroidShareChatPicker =
    Future<ChatSummary?> Function(BuildContext context);

/// Delivers a text-only share: the reference client drops the shared text into
/// the chosen chat's composer and opens it.
typedef AndroidShareTextSender =
    Future<void> Function(BuildContext context, ChatSummary chat, String text);

/// Runs the media preview and the send for the chosen chat.
typedef AndroidShareFileSender =
    Future<void> Function(
      BuildContext context,
      ChatSummary chat,
      List<AndroidSharedFile> files,
      String caption,
    );

/// Tells the user a share could not be prepared. Every branch that used to
/// return silently calls this instead.
typedef AndroidShareFailureReporter = void Function(BuildContext context);

class AndroidShareIntake {
  AndroidShareIntake({
    required this.pickChat,
    required this.sendText,
    required this.sendFiles,
    required this.reportFailure,
    AndroidShareSource? source,
  }) : source = source ?? AndroidShareIntentController.shared;

  final AndroidShareSource source;
  final AndroidShareChatPicker pickChat;
  final AndroidShareTextSender sendText;
  final AndroidShareFileSender sendFiles;
  final AndroidShareFailureReporter reportFailure;

  bool _presenting = false;

  /// Presents every queued share, one at a time.
  ///
  /// Draining the queue here (rather than asking the host to schedule another
  /// pass) keeps a share that arrived while the picker was open from waiting
  /// for an event that never comes.
  Future<void> presentPending(BuildContext context) async {
    if (_presenting) return;
    _presenting = true;
    try {
      var payload = source.takePending();
      while (payload != null) {
        await _presentOne(context, payload);
        if (!context.mounted) return;
        payload = source.takePending();
      }
    } finally {
      _presenting = false;
    }
  }

  Future<void> _presentOne(
    BuildContext context,
    AndroidShareIntentPayload payload,
  ) async {
    // Start the copy now so it runs while the user is choosing a chat, but
    // never wait for it before showing the picker. The batch carries its own
    // failure so the future can never surface as an unhandled error while the
    // picker is open.
    final batch = _copyPayload(payload);
    final copiedPaths = <String>[];
    try {
      final picked = await pickChat(context);
      if (!context.mounted) return;

      final copied = await batch;
      // Collected before the cancel check so a picker the user backed out of
      // still has its private copies removed.
      copiedPaths.addAll(copied.files.map((file) => file.path));
      if (!context.mounted || picked == null) return;
      if (copied.failed) {
        reportFailure(context);
        return;
      }
      final files = copied.files;

      if (files.isEmpty) {
        if (payload.text.trim().isEmpty) {
          // The provider answered with nothing at all: say so instead of
          // closing the flow as if the share had never happened.
          reportFailure(context);
          return;
        }
        await sendText(context, picked, payload.text);
        return;
      }
      await sendFiles(context, picked, files, payload.text);
    } finally {
      await source.deleteFiles(copiedPaths);
    }
  }

  Future<_FileBatch> _copyPayload(AndroidShareIntentPayload payload) async {
    if (payload.uris.isEmpty) {
      return const _FileBatch(files: <AndroidSharedFile>[]);
    }
    try {
      return _FileBatch(files: await source.copyFiles(payload.uris));
    } on AndroidShareCopyException {
      return const _FileBatch(files: <AndroidSharedFile>[], failed: true);
    }
  }
}

/// The provider's answer, kept separate from "no file was shared": the first is
/// a failure the user must see, the second is whatever the picker's chat gets.
class _FileBatch {
  const _FileBatch({required this.files, this.failed = false});

  final List<AndroidSharedFile> files;
  final bool failed;
}
