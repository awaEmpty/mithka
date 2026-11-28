//
//  topic_tabs_reorder_test.dart
//
//  exteraless lets a pinned topic's menu rearrange the topic tabs
//  (FilterReorder -> channels.reorderPinnedForumTopics). The fork stores the
//  same order through TDLib's setPinnedForumTopics and reorders the strip,
//  rail and topic list optimistically, reloading the server order on refusal.
//

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/forum_topic_index.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = -1001234567890;

Map<String, dynamic> _topic(int id, String name, {required bool pinned}) => {
  '@type': 'forumTopic',
  'info': {'@type': 'forumTopicInfo', 'forum_topic_id': id, 'name': name},
  'is_pinned': pinned,
  'unread_count': 0,
  'last_read_inbox_message_id': 0,
  'notification_settings': {'@type': 'chatNotificationSettings', 'mute_for': 0},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<Map<String, dynamic>> updates;
  late List<Map<String, dynamic>> requests;

  setUpAll(() async {
    await AppStrings.ensureLoaded(const Locale('en'));
    updates = StreamController<Map<String, dynamic>>.broadcast();
    requests = [];
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'getForumTopics') {
            return <String, dynamic>{
              '@type': 'forumTopics',
              'total_count': 3,
              'topics': [
                _topic(20, 'Pinned B', pinned: true),
                _topic(10, 'Pinned A', pinned: true),
                _topic(30, 'Recent', pinned: false),
              ],
            };
          }
          return <String, dynamic>{'@type': 'ok'};
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests.clear();
  });

  ChatViewModel model() =>
      ChatViewModel(chatId: _chatId, title: 'Forum', markReadOnOpen: false)
        ..isForum = true
        ..canManageTopics = true
        ..forumTopics = const [
          ForumTopicOption(id: 10, name: 'Pinned A', isPinned: true),
          ForumTopicOption(id: 20, name: 'Pinned B', isPinned: true),
          ForumTopicOption(id: 30, name: 'Recent'),
        ];

  test(
    'reordering pins sends setPinnedForumTopics and reorders the tabs',
    () async {
      final viewModel = model();
      addTearDown(viewModel.dispose);
      expect(viewModel.canReorderPinnedTopics, isTrue);

      final error = await viewModel.reorderPinnedForumTopics([20, 10]);

      expect(error, isNull);
      final request = requests.firstWhere(
        (request) => request['@type'] == 'setPinnedForumTopics',
      );
      expect(request['chat_id'], _chatId);
      expect(request['forum_topic_ids'], [20, 10]);
      // Unpinned topics keep following the pins, never interleaved.
      expect(viewModel.forumTopics.map((topic) => topic.id).toList(), [
        20,
        10,
        30,
      ]);
    },
  );

  test('reordering needs rights and at least two pins', () async {
    final noRights = model()..canManageTopics = false;
    addTearDown(noRights.dispose);
    expect(noRights.canReorderPinnedTopics, isFalse);
    expect(await noRights.reorderPinnedForumTopics([20, 10]), isNull);
    expect(
      requests.where((request) => request['@type'] == 'setPinnedForumTopics'),
      isEmpty,
    );

    final onePin = model()
      ..forumTopics = const [
        ForumTopicOption(id: 10, name: 'Pinned A', isPinned: true),
        ForumTopicOption(id: 30, name: 'Recent'),
      ];
    addTearDown(onePin.dispose);
    expect(onePin.canReorderPinnedTopics, isFalse);
  });

  test('the shared index keeps the dragged pin order', () {
    const slot = 21;
    const chatId = 741;
    final index = ForumTopicIndex.shared;
    index.storeAll(slot, chatId, [
      const ForumTopicIndexEntry(id: 10, name: 'A', isPinned: true),
      const ForumTopicIndexEntry(id: 11, name: 'B', isPinned: true),
      const ForumTopicIndexEntry(id: 20, name: 'Recent', lastMessageId: 99),
    ]);
    addTearDown(() => index.storeAll(slot, chatId, const []));

    index.reorderPinned(slot, chatId, [11, 10]);

    expect(
      index.topicsFor(slot, chatId).map((entry) => entry.id).toList(),
      [11, 10, 20],
      reason: 'pins follow the drag, unpinned stays behind by activity',
    );
  });
}
