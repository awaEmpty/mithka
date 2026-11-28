//
//  reaction_reactor_avatars.dart
//
//  Names and photos for the senders behind a reaction bucket.
//
//  The reference client replaces a small reaction count with the reactors'
//  avatars (`ReactionsLayoutInBubble`: `reactionCount.count <= 3 &&
//  totalCount <= 3` → `button.setUsers(...)`, count zeroed). TDLib reports the
//  ids in `messageReactions.recent_reactions`; the profile facts come from the
//  same `getUser`/`getChat` calls the reactor sheet already makes. One
//  process-wide cache keeps a transcript full of chips from re-querying the
//  same senders, and an unresolvable id simply renders no avatar.
//

import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';
import '../../tdlib/json_helpers.dart';
import '../../tdlib/td_client.dart';
import '../../tdlib/td_models.dart';

@immutable
class ReactionReactorAvatar {
  const ReactionReactorAvatar({
    required this.title,
    this.photo,
    this.isDeleted = false,
  });

  final String title;
  final TdFileRef? photo;
  final bool isDeleted;
}

class ReactionReactorAvatars {
  ReactionReactorAvatars._();

  static final ReactionReactorAvatars shared = ReactionReactorAvatars._();

  final Map<int, ReactionReactorAvatar> _resolved = {};
  final Map<int, Future<ReactionReactorAvatar?>> _inFlight = {};

  /// Already-known facts for [senderId], or null when the first lookup has not
  /// answered yet. Widgets read this synchronously and rebuild on the future.
  ReactionReactorAvatar? peek(int senderId) => _resolved[senderId];

  Future<ReactionReactorAvatar?> resolve(int senderId) {
    final cached = _resolved[senderId];
    if (cached != null) return Future.value(cached);
    return _inFlight.putIfAbsent(senderId, () async {
      try {
        final avatar = await _load(senderId);
        if (avatar != null) _resolved[senderId] = avatar;
        return avatar;
      } catch (_) {
        // A preview surface without a live client, a deleted account, or a
        // transient failure: the chip falls back to its count.
        return null;
      } finally {
        _inFlight.remove(senderId)?.ignore();
      }
    });
  }

  Future<ReactionReactorAvatar?> _load(int senderId) async {
    if (senderId > 0) {
      final user = await TdClient.shared.query({
        '@type': 'getUser',
        'user_id': senderId,
      });
      return ReactionReactorAvatar(
        title: TDParse.userName(user),
        photo: TDParse.smallPhoto(user.obj('profile_photo')),
        isDeleted: TDParse.isDeletedUser(user),
      );
    }
    final chat = await TdClient.shared.query({
      '@type': 'getChat',
      'chat_id': senderId,
    });
    return ReactionReactorAvatar(
      title:
          chat.str('title') ?? AppStrings.t(AppStringKeys.chatInfoGroupMembers),
      photo: TDParse.smallPhoto(chat.obj('photo')),
    );
  }

  /// Test seam: forget every cached sender.
  void resetForTesting() {
    _resolved.clear();
    _inFlight.clear();
  }
}
