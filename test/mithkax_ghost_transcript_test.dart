//
//  Ghost bubbles and mirror lookups on the chat surface (Telegram §1.4
//  self-build, gated): deleted entries fold into the transcript as
//  translucent ghosts behind the render switch, reply anchors fill from
//  the mirror when the live target is gone, and ghosts keep attribution
//  and never render empty.
//

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/config/build_flags.dart';
import 'package:mithka/history/message_history_settings.dart';
import 'package:mithka/history/message_history_store.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = allowTelegramTosViolations;

const _accountUserId = 9101;
const _chatId = 21;

MessageHistoryEntry _deletedGhostEntry(
  int messageId, {
  String text = 'vanished',
  int senderId = 42,
}) => MessageHistoryEntry(
  accountUserId: _accountUserId,
  chatId: _chatId,
  messageId: messageId,
  senderId: senderId,
  date: 1700000000 + messageId,
  text: text,
  kindKey: '',
  state: MessageHistoryState.deleted,
  deletedAt: 1700009999,
  events: const [],
);

MessageHistoryEntry _keptEntry(
  int messageId, {
  String text = 'the deleted original',
  int senderId = 42,
}) => MessageHistoryEntry(
  accountUserId: _accountUserId,
  chatId: _chatId,
  messageId: messageId,
  senderId: senderId,
  date: 1700000000 + messageId,
  text: text,
  kindKey: '',
  state: MessageHistoryState.deleted,
  deletedAt: 1700009999,
  events: const [],
);

ChatMessage _reply(int id, int replyToId) => ChatMessage(
  id: id,
  isOutgoing: false,
  text: 'the reply',
  date: 1700000500,
  chatId: _chatId,
  senderId: 7,
)..replyToMessageId = replyToId;

void main() {
  if (!_enabled) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessageHistoryStore store;
  Map<String, dynamic> Function(Map<String, dynamic> request)? proxyQuery;

  setUpAll(() {
    // The TDLib proxy can be configured only once per process; the mirror
    // reconciliation tests swap the answer through [proxyQuery].
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async =>
            proxyQuery?.call(request) ?? <String, dynamic>{'@type': 'ok'},
        send: (_) async {},
        updates: const Stream<Map<String, dynamic>>.empty(),
      ),
    );
  });

  tearDownAll(TdClient.shared.closeProxy);

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    store = MessageHistoryStore.forTesting();
    store.updateSource = (_) => const Stream<Map<String, dynamic>>.empty();
    store.activeSlotChangeSource = () => const Stream<int>.empty();
    store.activeClientIdProvider = () => 1;
    ChatViewModel.accountSummaryProvider = (_) => AccountSummary(
      slot: 0,
      userId: _accountUserId,
      name: 'me',
      phone: '+1',
    );
  });

  tearDown(() {
    ChatViewModel.accountSummaryProvider = null;
    final settings = MessageHistorySettings.shared;
    settings.setRenderGhosts(false);
    store.dispose();
  });

  ChatViewModel makeViewModel() => ChatViewModel(
    chatId: _chatId,
    title: 'test',
    markReadOnOpen: false,
    historyStoreOverride: store,
  );

  group('ghost transcript', () {
    test('ghosts stay out while the render switch is off (the default)', () {
      store.debugSeed([_deletedGhostEntry(100)]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      expect(vm.messages.where((m) => m.mirrorEntry != null), isEmpty);
    });

    test('deleted entries fold into the transcript when ghosts are on', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      ChatViewModel.accountSummaryProvider = (_) => AccountSummary(
        slot: 0,
        userId: _accountUserId,
        name: 'me',
        phone: '+1',
      );
      store.debugSeed([
        _deletedGhostEntry(100),
        _deletedGhostEntry(300, text: 'later ghost'),
        // A live message's kept copy is NOT a ghost — the bubble renders it.
        _deletedGhostEntry(200).copyWith(state: MessageHistoryState.active),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      final ghosts = vm.messages.where((m) => m.mirrorEntry != null).toList();
      expect(ghosts.map((m) => m.id), [100, 300]);
      // The ghost carries the kept text and marks the bubble layer.
      expect(ghosts.first.text, 'vanished');
      expect(ghosts.first.contentType, 'mithkaGhost');
      // Ghosts join only `messages` — the id indexes stay clean.
      expect(vm.debugAllMessageIdsForTesting(), isEmpty);
    });

    test('a ghost whose message still loads as live is not duplicated', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      ChatViewModel.accountSummaryProvider = (_) => AccountSummary(
        slot: 0,
        userId: _accountUserId,
        name: 'me',
        phone: '+1',
      );
      store.debugSeed([_deletedGhostEntry(100)]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugMergeMessagesForTesting([
        ChatMessage(id: 100, isOutgoing: false, text: 'back', date: 1700000000),
      ]);
      vm.debugRebuildTranscriptForTesting();
      expect(vm.messages.where((m) => m.mirrorEntry != null), isEmpty);
      expect(vm.messages.map((m) => m.id), contains(100));
    });

    test('turning the switch off removes the ghosts again', () {
      final settings = MessageHistorySettings.shared;
      settings.setRenderGhosts(true);
      store.debugSeed([_deletedGhostEntry(100)]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      expect(vm.messages.where((m) => m.mirrorEntry != null), isNotEmpty);
      settings.setRenderGhosts(false);
      vm.debugRebuildTranscriptForTesting();
      expect(vm.messages.where((m) => m.mirrorEntry != null), isEmpty);
    });
  });

  group('mirror reply anchors', () {
    test('a deleted reply target fills its anchor from the mirror', () {
      store.debugSeed([_keptEntry(100)]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugMergeMessagesForTesting([_reply(101, 100)]);
      final reply = vm.messages.firstWhere((m) => m.id == 101);
      expect(reply.replyToPreview, 'the deleted original');
      expect(reply.replyToDate, 1700000100);
    });

    test('a live target in the transcript wins over the mirror', () {
      store.debugSeed([_keptEntry(100, text: 'mirror copy')]);
      final live = ChatMessage(
        id: 100,
        isOutgoing: false,
        text: 'the live original',
        date: 1700000100,
        chatId: _chatId,
        senderId: 42,
      );
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugMergeMessagesForTesting([live, _reply(101, 100)]);
      final reply = vm.messages.firstWhere((m) => m.id == 101);
      expect(reply.replyToPreview, 'the live original');
    });

    test('no mirror copy leaves the reply to the normal TDLib path', () {
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugMergeMessagesForTesting([_reply(101, 100)]);
      final reply = vm.messages.firstWhere((m) => m.id == 101);
      expect(reply.replyToPreview, isNull);
    });

    test('a media-only kept copy fills the kind label, not empty text', () {
      store.debugSeed([
        _keptEntry(100, text: '').copyWith(kindKey: 'historyKindPhoto'),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugMergeMessagesForTesting([_reply(101, 100)]);
      final reply = vm.messages.firstWhere((m) => m.id == 101);
      // Localized through AppStrings (ambient locale, no BuildContext).
      expect(
        reply.replyToPreview,
        AppStrings.t(AppStringKeys.historyKindPhoto),
      );
    });
  });

  group('mirror reconciliation', () {
    tearDown(() => proxyQuery = null);

    test(
      'a wrongly recorded deletion is repaired by the server probe',
      () async {
        proxyQuery = (request) {
          if (request['@type'] != 'getMessages') {
            return <String, dynamic>{'@type': 'ok'};
          }
          return <String, dynamic>{
            '@type': 'messages',
            'total_count': 1,
            'messages': [
              {
                '@type': 'message',
                'id': 100,
                'chat_id': _chatId,
                'date': 1700000000,
                'content': {
                  '@type': 'messageText',
                  'text': {'@type': 'formattedText', 'text': 'alive'},
                },
              },
            ],
          };
        };

        // The mirror believes the message is gone; the server still has it.
        store.debugSeed([_deletedGhostEntry(100)]);
        final vm = makeViewModel();
        addTearDown(vm.dispose);
        await vm.debugReconcileMirrorGhostsForTesting();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final entry = store.entryFor(_accountUserId, _chatId, 100)!;
        expect(entry.state, MessageHistoryState.active);
        expect(entry.deletedAt, 0);
      },
    );

    test('a probe that finds nothing keeps the deletion', () async {
      proxyQuery = (request) {
        if (request['@type'] != 'getMessages') {
          return <String, dynamic>{'@type': 'ok'};
        }
        // TDLib answers unavailable ids as placeholders without an id.
        return <String, dynamic>{
          '@type': 'messages',
          'total_count': 0,
          'messages': [
            {'@type': 'message', 'id': 0, 'chat_id': _chatId},
          ],
        };
      };

      store.debugSeed([_deletedGhostEntry(100)]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      await vm.debugReconcileMirrorGhostsForTesting();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        store.entryFor(_accountUserId, _chatId, 100)!.state,
        MessageHistoryState.deleted,
      );
    });
  });

  group('ghost attribution', () {
    test('a self-sent ghost carries the account name', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      store.debugSeed([
        const MessageHistoryEntry(
          accountUserId: _accountUserId,
          chatId: _chatId,
          messageId: 100,
          senderId: _accountUserId,
          date: 1,
          text: 'mine',
          kindKey: '',
          state: MessageHistoryState.deleted,
          deletedAt: 2,
          events: [],
        ),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      final ghost = vm.messages.firstWhere((m) => m.mirrorEntry != null);
      expect(ghost.isOutgoing, isTrue);
      expect(ghost.senderName, 'Me');
    });

    test('a group ghost resolves its sender avatar', () async {
      MessageHistorySettings.shared.setRenderGhosts(true);
      proxyQuery = (request) {
        if (request['@type'] == 'getUser') {
          return {
            '@type': 'user',
            'id': 42,
            'first_name': 'Alice',
            'last_name': 'Ann',
            'usernames': {
              '@type': 'usernames',
              'active_usernames': [],
              'disabled_usernames': [],
              'editable_username': '',
            },
            'profile_photo': {
              '@type': 'profilePhoto',
              'id': 900,
              'small': {
                '@type': 'file',
                'id': 901,
                'size': 1600,
                'expected_size': 1600,
                'local': {
                  '@type': 'localFile',
                  'path': '/tmp/alice.jpg',
                  'can_be_downloaded': true,
                  'is_downloading_completed': true,
                },
                'remote': {
                  '@type': 'remoteFile',
                  'id': 'alice-small',
                  'unique_id': 'alice-small',
                  'is_uploading_active': false,
                  'is_uploading_completed': true,
                  'uploaded_size': 1600,
                },
              },
              'big': {'@type': 'file', 'id': 902},
            },
          };
        }
        return <String, dynamic>{'@type': 'ok'};
      };
      addTearDown(() => proxyQuery = null);

      store.debugSeed([_deletedGhostEntry(102)]);
      final vm = makeViewModel();
      vm.isGroup = true;
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      for (var i = 0; i < 100; i++) {
        final ghost = vm.messages
            .where((m) => m.mirrorEntry != null)
            .firstOrNull;
        if (ghost?.senderPhoto != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final ghost = vm.messages.firstWhere((m) => m.mirrorEntry != null);
      expect(ghost.senderName, 'Alice Ann');
      expect(ghost.senderPhoto, isNotNull);
      expect(ghost.senderPhoto!.id, 901);
    });

    test('a media-only ghost shows the localized kind label', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      store.debugSeed([
        const MessageHistoryEntry(
          accountUserId: _accountUserId,
          chatId: _chatId,
          messageId: 101,
          senderId: 42,
          date: 1,
          text: '',
          kindKey: 'historyKindPhoto',
          state: MessageHistoryState.deleted,
          deletedAt: 2,
          events: [],
        ),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      final ghost = vm.messages.firstWhere((m) => m.mirrorEntry != null);
      expect(
        ghost.text,
        AppStrings.t(AppStringKeys.historyKindPhoto),
        reason: 'an empty media ghost must not render as an empty bubble',
      );
    });
    test('a media ghost with a snapshot keeps the caption, not the label', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      store.debugSeed([
        const MessageHistoryEntry(
          accountUserId: _accountUserId,
          chatId: _chatId,
          messageId: 102,
          senderId: 42,
          date: 1,
          text: 'look at this',
          kindKey: 'historyKindPhoto',
          state: MessageHistoryState.deleted,
          deletedAt: 2,
          events: [],
          mediaPath: '/tmp/kept-photo.jpg',
          mediaWidth: 320,
          mediaHeight: 240,
        ),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      final ghost = vm.messages.firstWhere((m) => m.mirrorEntry != null);
      // The bubble paints the snapshot itself, so the kind label must not
      // print underneath it; only a real caption stays as text.
      expect(ghost.text, 'look at this');
    });

    test('a media ghost without a caption has no label text', () {
      MessageHistorySettings.shared.setRenderGhosts(true);
      store.debugSeed([
        const MessageHistoryEntry(
          accountUserId: _accountUserId,
          chatId: _chatId,
          messageId: 103,
          senderId: 42,
          date: 1,
          text: '',
          kindKey: 'historyKindPhoto',
          state: MessageHistoryState.deleted,
          deletedAt: 2,
          events: [],
          mediaPath: '/tmp/kept-photo.jpg',
          mediaWidth: 320,
          mediaHeight: 240,
        ),
      ]);
      final vm = makeViewModel();
      addTearDown(vm.dispose);
      vm.debugRebuildTranscriptForTesting();
      final ghost = vm.messages.firstWhere((m) => m.mirrorEntry != null);
      expect(ghost.text, isEmpty);
    });
  });
}
