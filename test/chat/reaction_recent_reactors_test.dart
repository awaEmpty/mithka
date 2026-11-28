//
//  reaction_recent_reactors_test.dart
//
//  `messageReactions.recent_reactions` names the last senders per bucket. The
//  reference client uses them for the avatar chips, so the parser has to keep
//  each bucket's own senders — a flat list would show a 👍 reactor under 🔥.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/tdlib/td_models.dart';

Map<String, dynamic> _peer(int userId) => {
  '@type': 'messageSenderUser',
  'user_id': userId,
};

Map<String, dynamic> _reactionCount(
  String emoji,
  int count, {
  bool chosen = false,
}) => {
  '@type': 'reactionCount',
  'type': {'@type': 'reactionTypeEmoji', 'emoji': emoji},
  'total_count': count,
  'is_chosen': chosen,
};

Map<String, dynamic> _recent(String emoji, int userId) => {
  '@type': 'messagePeerReaction',
  'peer_id': _peer(userId),
  'date': 1700000000,
  'reaction': {'@type': 'reactionTypeEmoji', 'emoji': emoji},
};

void main() {
  test('each bucket keeps only its own recent senders', () {
    final message = {
      '@type': 'message',
      'id': 1,
      'chat_id': -100123,
      'date': 1700000000,
      'interaction_info': {
        '@type': 'messageInteractionInfo',
        'reactions': {
          '@type': 'messageReactions',
          'total_count': 3,
          'reactions': [
            _reactionCount('👍', 2, chosen: true),
            _reactionCount('🔥', 1),
          ],
          'recent_reactions': [
            _recent('👍', 10),
            _recent('🔥', 11),
            _recent('👍', 12),
          ],
        },
      },
    };

    final reactions = TDParse.reactionsFrom(message);
    expect(reactions, hasLength(2));
    expect(reactions[0].emoji, '👍');
    expect(reactions[0].count, 2);
    expect(reactions[0].chosen, isTrue);
    expect(
      reactions[0].reactors.map((r) => r.senderId).toList(),
      [10, 12],
      reason: 'the 👍 bucket lists its own senders, in TDLib order',
    );
    expect(reactions[1].emoji, '🔥');
    expect(reactions[1].reactors.map((r) => r.senderId).toList(), [11]);
  });

  test('a custom-emoji bucket matches by document id', () {
    final message = {
      '@type': 'message',
      'id': 1,
      'chat_id': -100123,
      'date': 1700000000,
      'interaction_info': {
        '@type': 'messageInteractionInfo',
        'reactions': {
          '@type': 'messageReactions',
          'total_count': 1,
          'reactions': [
            {
              '@type': 'reactionCount',
              'type': {
                '@type': 'reactionTypeCustomEmoji',
                'custom_emoji_id': '5372981976804366741',
              },
              'total_count': 1,
              'is_chosen': false,
            },
          ],
          'recent_reactions': [
            {
              '@type': 'messagePeerReaction',
              'peer_id': {'@type': 'messageSenderChat', 'chat_id': -100999},
              'date': 1700000000,
              'reaction': {
                '@type': 'reactionTypeCustomEmoji',
                'custom_emoji_id': '5372981976804366741',
              },
            },
          ],
        },
      },
    };

    final reactions = TDParse.reactionsFrom(message);
    expect(reactions, hasLength(1));
    expect(reactions.single.customEmojiId, 5372981976804366741);
    expect(reactions.single.reactors.single.senderId, -100999);
  });
}
