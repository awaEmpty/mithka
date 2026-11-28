import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/group_scheduled_deletion.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/privacy_security/privacy_security_view.dart';
import 'package:mithka/settings/privacy_security/sensitive_content_controller.dart';
import 'package:mithka/settings/scheduled_deletion_view.dart';
import 'package:mithka/tdlib/json_helpers.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The scheduled-deletion controller must only enqueue messages this account
// sends in plain groups without a server-side timer, survive restarts through
// SharedPreferences, delete in batches, and retry transient failures without
// ever touching private chats or channels.

const int _startSeconds = 1700000000;
const int _startMillis = _startSeconds * 1000;
const int _dayMillis = 86400 * 1000;

class _Clock {
  _Clock(this.nowMillis);

  int nowMillis;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMillis);

  void advance(int millis) => nowMillis += millis;
}

class _FakeTransport implements ScheduledDeletionTransport {
  _FakeTransport({Map<int, int>? clientSlots, Set<int>? botApiSlots})
    : clientSlots = clientSlots ?? {1: 0},
      botApiSlots = botApiSlots ?? {};

  final Map<int, int> clientSlots;
  final Set<int> botApiSlots;
  final Map<String, StreamController<Map<String, dynamic>>> _streams = {
    for (final type in const [
      'updateNewMessage',
      'updateMessageSendSucceeded',
      'updateChatMessageAutoDeleteTime',
      'updateAuthorizationState',
    ])
      type: StreamController<Map<String, dynamic>>.broadcast(sync: true),
  };

  /// Recorded as (slot, request) so account routing is asserted, not assumed.
  final List<({int slot, Map<String, dynamic> request})> queries = [];

  Map<String, dynamic> Function(Map<String, dynamic> request)? answer;

  @override
  Stream<Map<String, dynamic>> updates(String type) => _streams[type]!.stream;

  @override
  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request,
    int slot,
  ) async {
    queries.add((slot: slot, request: Map<String, dynamic>.of(request)));
    final responder = answer;
    if (responder == null) return {'@type': 'ok'};
    final response = responder(request);
    if (response.type == 'error') throw TdError(response);
    return response;
  }

  @override
  int? slotForClient(int clientId) => clientSlots[clientId];

  @override
  bool isBotApiSlot(int slot) => botApiSlots.contains(slot);

  void emit(String type, Map<String, dynamic> update) =>
      _streams[type]!.add(update);

  List<Map<String, dynamic>> requestsOf(String type) => [
    for (final entry in queries)
      if (entry.request.type == type) entry.request,
  ];

  List<int> slotsOf(String type) => [
    for (final entry in queries)
      if (entry.request.type == type) entry.slot,
  ];

  Future<void> close() async {
    for (final controller in _streams.values) {
      await controller.close();
    }
  }
}

Map<String, dynamic> _groupChat(int chatId, {int autoDelete = 0}) => {
  '@type': 'chat',
  'id': chatId,
  'title': 'Group $chatId',
  'type': {'@type': 'chatTypeBasicGroup', 'basic_group_id': chatId},
  'message_auto_delete_time': {
    '@type': 'messageAutoDeleteTime',
    'time': autoDelete,
  },
};

Map<String, dynamic> _privateChat(int chatId) => {
  '@type': 'chat',
  'id': chatId,
  'title': 'Person $chatId',
  'type': {'@type': 'chatTypePrivate', 'user_id': chatId},
};

Map<String, dynamic> _channelChat(int chatId) => {
  '@type': 'chat',
  'id': chatId,
  'title': 'Channel $chatId',
  'type': {
    '@type': 'chatTypeSupergroup',
    'supergroup_id': chatId,
    'is_channel': true,
  },
};

Map<String, dynamic> _messageUpdate({
  required String type,
  required int chatId,
  required int messageId,
  int clientId = 1,
  bool outgoing = true,
  bool pending = false,
  String contentType = 'messageText',
  int date = _startSeconds,
}) => {
  '@type': type,
  '@client_id': clientId,
  if (type == 'updateMessageSendSucceeded') 'old_message_id': -messageId,
  'message': {
    '@type': 'message',
    'id': messageId,
    'chat_id': chatId,
    'date': date,
    'is_outgoing': outgoing,
    'content': {'@type': contentType},
    if (pending) 'sending_state': {'@type': 'messageSendingStatePending'},
  },
};

String _pendingKey(int slot, int chatId) =>
    '${GroupScheduledDeletionController.pendingPreferencePrefix}$slot.$chatId';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
  });

  Future<GroupScheduledDeletionController> build(
    WidgetTester tester,
    _FakeTransport fake,
    _Clock clock,
  ) async {
    final controller = GroupScheduledDeletionController(
      transport: fake,
      clock: clock.now,
    );
    controller.initialize(prefs);
    addTearDown(fake.close);
    return controller;
  }

  testWidgets('defaults to off with a one-day delay', (tester) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);

    expect(controller.enabled, isFalse);
    expect(controller.durationSeconds, 86400);
    expect(controller.pendingMessageCount, 0);

    await controller.setEnabled(true);
    await controller.setDurationSeconds(3600);
    expect(
      prefs.getBool(GroupScheduledDeletionController.enabledPreferenceKey),
      isTrue,
    );
    expect(
      prefs.getInt(GroupScheduledDeletionController.durationPreferenceKey),
      3600,
    );

    await controller.setEnabled(false);
    expect(
      prefs.getBool(GroupScheduledDeletionController.enabledPreferenceKey),
      isFalse,
    );
    controller.dispose();
  });

  testWidgets('queues only outgoing group messages without a server timer', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] != 'getChat') return {'@type': 'ok'};
      return switch (request['chat_id'] as int) {
        11 => _groupChat(11),
        12 => _privateChat(12),
        13 => _channelChat(13),
        14 => _groupChat(14, autoDelete: 86400),
        _ => _groupChat(request['chat_id'] as int),
      };
    };

    for (final (chatId, messageId) in const [
      (11, 101),
      (12, 102),
      (13, 103),
      (14, 104),
    ]) {
      fake.emit(
        'updateNewMessage',
        _messageUpdate(
          type: 'updateNewMessage',
          chatId: chatId,
          messageId: messageId,
        ),
      );
    }
    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 11,
        messageId: 105,
        outgoing: false,
      ),
    );
    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 11,
        messageId: 106,
        contentType: 'messageChatJoinByLink',
      ),
    );
    await tester.pump();

    expect(controller.pendingMessageCount, 1);
    expect(controller.msgIdsForTesting(0, 11), [101]);
    expect(prefs.getString(_pendingKey(0, 11)), contains('101'));
    expect(prefs.getString(_pendingKey(0, 12)), isNull);
    expect(prefs.getString(_pendingKey(0, 13)), isNull);
    expect(prefs.getString(_pendingKey(0, 14)), isNull);
    controller.dispose();
  });

  testWidgets('a pending send is ignored until its real id arrives', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) =>
        request['@type'] == 'getChat' ? _groupChat(21) : {'@type': 'ok'};

    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 21,
        messageId: -5,
        pending: true,
      ),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 0);

    fake.emit(
      'updateMessageSendSucceeded',
      _messageUpdate(
        type: 'updateMessageSendSucceeded',
        chatId: 21,
        messageId: 500,
      ),
    );
    await tester.pump();
    expect(controller.msgIdsForTesting(0, 21), [500]);
    controller.dispose();
  });

  testWidgets('a repeated update never duplicates a message', (tester) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) =>
        request['@type'] == 'getChat' ? _groupChat(22) : {'@type': 'ok'};

    final update = _messageUpdate(
      type: 'updateNewMessage',
      chatId: 22,
      messageId: 600,
    );
    fake.emit('updateNewMessage', update);
    fake.emit('updateNewMessage', update);
    fake.emit(
      'updateMessageSendSucceeded',
      _messageUpdate(
        type: 'updateMessageSendSucceeded',
        chatId: 22,
        messageId: 600,
      ),
    );
    await tester.pump();

    expect(controller.msgIdsForTesting(0, 22), [600]);
    controller.dispose();
  });

  testWidgets('Bot API accounts are never scheduled', (tester) async {
    final fake = _FakeTransport(botApiSlots: {0});
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 30, messageId: 700),
    );
    await tester.pump();

    expect(controller.pendingMessageCount, 0);
    expect(fake.requestsOf('getChat'), isEmpty);
    controller.dispose();
  });

  testWidgets('a message older than the window is due immediately', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) =>
        request['@type'] == 'getChat' ? _groupChat(31) : {'@type': 'ok'};

    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 31,
        messageId: 800,
        date: _startSeconds - 2 * 86400,
      ),
    );
    await tester.pump();

    await controller.flushDue();
    final delete = fake.requestsOf('deleteMessages').single;
    expect(delete['message_ids'], [800]);
    controller.dispose();
  });

  testWidgets('flushing deletes for everyone on the message account', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(40);
      return {'@type': 'ok'};
    };

    fake.emit(
      'updateMessageSendSucceeded',
      _messageUpdate(
        type: 'updateMessageSendSucceeded',
        chatId: 40,
        messageId: 900,
      ),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 1);

    // Not due yet: flushing early must not delete anything.
    await controller.flushDue();
    expect(fake.requestsOf('deleteMessages'), isEmpty);

    clock.advance(_dayMillis);
    await controller.flushDue();

    final delete = fake.requestsOf('deleteMessages').single;
    expect(delete['chat_id'], 40);
    expect(delete['message_ids'], [900]);
    expect(delete['revoke'], isTrue);
    expect(fake.slotsOf('deleteMessages'), [0]);
    expect(controller.pendingMessageCount, 0);
    expect(prefs.getString(_pendingKey(0, 40)), isNull);
    controller.dispose();
  });

  testWidgets('the timer fires at the deadline without an explicit flush', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    await controller.setDurationSeconds(3600);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(41);
      return {'@type': 'ok'};
    };

    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 41, messageId: 901),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 1);

    clock.advance(3600 * 1000);
    await tester.pump(const Duration(hours: 1));
    await tester.pump();

    expect(fake.requestsOf('deleteMessages').single['message_ids'], [901]);
    expect(controller.pendingMessageCount, 0);
    controller.dispose();
  });

  testWidgets('a restart reloads the persisted queue', (tester) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(50);
      return {'@type': 'ok'};
    };
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 50, messageId: 1000),
    );
    await tester.pump();
    expect(prefs.getString(_pendingKey(0, 50)), isNotNull);

    final secondFake = _FakeTransport();
    final second = GroupScheduledDeletionController(
      transport: secondFake,
      clock: clock.now,
    );
    secondFake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(50);
      return {'@type': 'ok'};
    };
    second.initialize(prefs);
    addTearDown(secondFake.close);
    expect(second.pendingMessageCount, 1);

    clock.advance(_dayMillis);
    await second.flushDue();
    expect(secondFake.requestsOf('deleteMessages').single['message_ids'], [
      1000,
    ]);
    controller.dispose();
    second.dispose();
  });

  testWidgets('disabling cancels the queue and persisted plans', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(51);
      return {'@type': 'ok'};
    };
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 51, messageId: 1001),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 1);

    await controller.setEnabled(false);
    expect(controller.pendingMessageCount, 0);
    expect(prefs.getString(_pendingKey(0, 51)), isNull);

    clock.advance(_dayMillis);
    await controller.flushDue();
    expect(fake.requestsOf('deleteMessages'), isEmpty);
    controller.dispose();
  });

  testWidgets('a stale queue is dropped when the feature is off at launch', (
    tester,
  ) async {
    await prefs.setString(
      _pendingKey(0, 52),
      '[[1002,${_startMillis + _dayMillis},0]]',
    );
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);

    expect(controller.pendingMessageCount, 0);
    expect(prefs.getString(_pendingKey(0, 52)), isNull);
    controller.dispose();
  });

  testWidgets('a group that turned on Auto-Delete is left to Telegram', (
    tester,
  ) async {
    var autoDelete = 0;
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') {
        return _groupChat(60, autoDelete: autoDelete);
      }
      return {'@type': 'ok'};
    };
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 60, messageId: 1100),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 1);

    autoDelete = 86400;
    clock.advance(_dayMillis);
    await controller.flushDue();

    expect(fake.requestsOf('deleteMessages'), isEmpty);
    expect(controller.pendingMessageCount, 0);
    expect(prefs.getString(_pendingKey(0, 60)), isNull);
    controller.dispose();
  });

  testWidgets('updateChatMessageAutoDeleteTime drops the local plan', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) =>
        request['@type'] == 'getChat' ? _groupChat(61) : {'@type': 'ok'};
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 61, messageId: 1101),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 1);

    fake.emit('updateChatMessageAutoDeleteTime', {
      '@type': 'updateChatMessageAutoDeleteTime',
      '@client_id': 1,
      'chat_id': 61,
      'message_auto_delete_time': {
        '@type': 'messageAutoDeleteTime',
        'time': 86400,
      },
    });
    await tester.pump();
    await tester.pump();

    expect(controller.pendingMessageCount, 0);
    expect(prefs.getString(_pendingKey(0, 61)), isNull);
    controller.dispose();
  });

  testWidgets('closing an account drops its queue and keeps the others', (
    tester,
  ) async {
    final fake = _FakeTransport(clientSlots: {1: 0, 2: 1});
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') {
        return _groupChat(request['chat_id'] as int);
      }
      return {'@type': 'ok'};
    };

    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 70, messageId: 1200),
    );
    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 71,
        messageId: 1201,
        clientId: 2,
      ),
    );
    await tester.pump();
    expect(controller.pendingMessageCount, 2);

    fake.emit('updateAuthorizationState', {
      '@type': 'updateAuthorizationState',
      '@client_id': 1,
      'authorization_state': {'@type': 'authorizationStateClosed'},
    });
    await tester.pump();
    await tester.pump();

    expect(controller.pendingMessageCount, 1);
    expect(controller.msgIdsForTesting(0, 70), isEmpty);
    expect(controller.msgIdsForTesting(1, 71), [1201]);
    controller.dispose();
  });

  testWidgets('two accounts delete through their own slots', (tester) async {
    final fake = _FakeTransport(clientSlots: {1: 0, 2: 1});
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') {
        return _groupChat(request['chat_id'] as int);
      }
      return {'@type': 'ok'};
    };

    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 72, messageId: 1300),
    );
    fake.emit(
      'updateNewMessage',
      _messageUpdate(
        type: 'updateNewMessage',
        chatId: 73,
        messageId: 1301,
        clientId: 2,
      ),
    );
    await tester.pump();
    clock.advance(_dayMillis);
    await controller.flushDue();

    final deletes = fake.requestsOf('deleteMessages');
    expect(deletes, hasLength(2));
    expect(
      fake.queries
          .where((entry) => entry.request.type == 'deleteMessages')
          .map((entry) => entry.slot)
          .toList(),
      [0, 1],
    );
    expect(controller.pendingMessageCount, 0);
    controller.dispose();
  });

  testWidgets('transient failures are retried, permanent ones dropped', (
    tester,
  ) async {
    var failWith = 500;
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(80);
      if (request['@type'] == 'deleteMessages' && failWith != 0) {
        return {'@type': 'error', 'code': failWith, 'message': 'failed'};
      }
      return {'@type': 'ok'};
    };
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 80, messageId: 1400),
    );
    await tester.pump();

    clock.advance(_dayMillis);
    await controller.flushDue();
    expect(controller.pendingMessageCount, 1);

    // The retry moved the deadline; it must be due again after the backoff.
    clock.advance(30 * 1000);
    failWith = 0;
    await controller.flushDue();
    expect(controller.pendingMessageCount, 0);

    // A 400 is final and must not stay queued forever.
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 80, messageId: 1401),
    );
    await tester.pump();
    failWith = 400;
    clock.advance(_dayMillis);
    await controller.flushDue();
    expect(controller.pendingMessageCount, 0);
    controller.dispose();
  });

  testWidgets('more than 100 ids are split into MTProto-sized batches', (
    tester,
  ) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(90);
      return {'@type': 'ok'};
    };
    for (var index = 0; index < 150; index++) {
      fake.emit(
        'updateNewMessage',
        _messageUpdate(
          type: 'updateNewMessage',
          chatId: 90,
          messageId: 2000 + index,
        ),
      );
    }
    await tester.pump();
    expect(controller.pendingMessageCount, 150);

    clock.advance(_dayMillis);
    await controller.flushDue();

    final deletes = fake.requestsOf('deleteMessages');
    expect(deletes, hasLength(2));
    expect((deletes[0]['message_ids'] as List).length, 100);
    expect((deletes[1]['message_ids'] as List).length, 50);
    expect(controller.pendingMessageCount, 0);
    controller.dispose();
  });

  testWidgets('resuming the app catches up overdue deletions', (tester) async {
    final fake = _FakeTransport();
    final clock = _Clock(_startMillis);
    final controller = await build(tester, fake, clock);
    await controller.setEnabled(true);
    fake.answer = (request) {
      if (request['@type'] == 'getChat') return _groupChat(91);
      return {'@type': 'ok'};
    };
    fake.emit(
      'updateNewMessage',
      _messageUpdate(type: 'updateNewMessage', chatId: 91, messageId: 3000),
    );
    await tester.pump();

    clock.advance(_dayMillis);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(fake.requestsOf('deleteMessages').single['message_ids'], [3000]);
    expect(controller.pendingMessageCount, 0);
    controller.dispose();
  });

  testWidgets('settings page persists the switch and delay', (tester) async {
    GroupScheduledDeletionController.shared.resetForTesting();
    GroupScheduledDeletionController.shared.initialize(prefs);
    addTearDown(GroupScheduledDeletionController.shared.resetForTesting);
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ScheduledDeletionSettingsView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scheduled deletion'), findsOneWidget);
    expect(find.text('Auto-delete my group messages'), findsOneWidget);
    expect(find.text('1 hour'), findsOneWidget);
    expect(find.text('1 month'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scheduled-delete-master')));
    await tester.pump();
    expect(GroupScheduledDeletionController.shared.enabled, isTrue);
    expect(
      prefs.getBool(GroupScheduledDeletionController.enabledPreferenceKey),
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('scheduled-delete-3600')));
    await tester.pump();
    expect(GroupScheduledDeletionController.shared.durationSeconds, 3600);
    expect(
      prefs.getInt(GroupScheduledDeletionController.durationPreferenceKey),
      3600,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('privacy screen shows the row and its current delay', (
    tester,
  ) async {
    final updates = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(updates.close);
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (_) async => <String, dynamic>{'@type': 'error'},
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    addTearDown(TdClient.shared.closeProxy);
    GroupScheduledDeletionController.shared.resetForTesting();
    GroupScheduledDeletionController.shared.initialize(prefs);
    addTearDown(GroupScheduledDeletionController.shared.resetForTesting);
    await GroupScheduledDeletionController.shared.setDurationSeconds(3600);
    await GroupScheduledDeletionController.shared.setEnabled(true);
    final theme = ThemeController(prefs);
    addTearDown(theme.dispose);

    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<SensitiveContentController>.value(
            value: SensitiveContentController.shared,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PrivacySecurityView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scheduled deletion'), findsOneWidget);
    expect(find.text('1 hour'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
