//
//  avatar_presence_test.dart
//
//  exteraless's avatar presence dot: online is green, then yellow / orange /
//  red for a last seen within 15 / 30 / 60 minutes. The feature is off by
//  default (NaConfig.showOnlineStatus).
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/photo_avatar.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';

void main() {
  const now = 1800000000;

  Map<String, dynamic> offline(int secondsAgo) => {
    '@type': 'userStatusOffline',
    'was_online': now - secondsAgo,
  };

  test('online is the green dot', () {
    expect(
      TDParse.avatarPresence({'@type': 'userStatusOnline'}, now: now),
      AvatarPresence.online,
    );
  });

  test('a bot never carries a presence dot', () {
    final bot = {
      '@type': 'user',
      'id': 42,
      'type': {'@type': 'userTypeBot'},
      'status': {'@type': 'userStatusOnline'},
    };
    expect(TDParse.userAvatarPresence(bot, now: now), AvatarPresence.none);
    final human = {
      '@type': 'user',
      'id': 43,
      'type': {'@type': 'userTypeRegular'},
      'status': {'@type': 'userStatusOnline'},
    };
    expect(TDParse.userAvatarPresence(human, now: now), AvatarPresence.online);
  });

  test('the last-seen bands map to the reference colours', () {
    expect(
      TDParse.avatarPresence(offline(5 * 60), now: now),
      AvatarPresence.within15Minutes,
    );
    expect(
      TDParse.avatarPresence(offline(20 * 60), now: now),
      AvatarPresence.within30Minutes,
    );
    expect(
      TDParse.avatarPresence(offline(45 * 60), now: now),
      AvatarPresence.within60Minutes,
    );
    expect(
      TDParse.avatarPresence(offline(2 * 60 * 60), now: now),
      AvatarPresence.none,
    );
  });

  test('coarse statuses and missing statuses draw nothing', () {
    for (final type in [
      'userStatusRecently',
      'userStatusLastWeek',
      'userStatusLastMonth',
      'userStatusEmpty',
    ]) {
      expect(
        TDParse.avatarPresence({'@type': type}, now: now),
        AvatarPresence.none,
        reason: type,
      );
    }
    expect(TDParse.avatarPresence(null, now: now), AvatarPresence.none);
  });

  test('the dot colours match the reference client', () {
    expect(avatarPresenceColor(AvatarPresence.online), AppTheme.onlineDot);
    expect(
      avatarPresenceColor(AvatarPresence.within15Minutes),
      const Color(0xFFEAEA1E),
    );
    expect(
      avatarPresenceColor(AvatarPresence.within30Minutes),
      const Color(0xFFEA841E),
    );
    expect(
      avatarPresenceColor(AvatarPresence.within60Minutes),
      const Color(0xFFEA1E1E),
    );
    expect(avatarPresenceColor(AvatarPresence.none), isNull);
  });

  testWidgets('PhotoAvatar paints the requested presence only', (tester) async {
    Future<void> pump(AvatarPresence presence, {bool legacy = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: PhotoAvatar(
              title: 'Ann',
              size: 48,
              showOnlineDot: legacy,
              onlinePresence: presence,
            ),
          ),
        ),
      );
    }

    await pump(AvatarPresence.none);
    expect(find.byKey(const ValueKey('avatar-presence-none')), findsNothing);

    await pump(AvatarPresence.within15Minutes);
    final dot = find.byKey(const ValueKey('avatar-presence-within15Minutes'));
    expect(dot, findsOneWidget);
    final container = tester.widget<Container>(dot);
    expect(
      (container.decoration! as BoxDecoration).color,
      const Color(0xFFEAEA1E),
    );

    await pump(AvatarPresence.none, legacy: true);
    expect(
      find.byKey(const ValueKey('avatar-presence-online')),
      findsOneWidget,
      reason: 'the contacts/members lists keep their boolean online dot',
    );
  });
}
