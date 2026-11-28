import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 1,
        accountUserId: 1,
        query: (request) async => switch (request['@type']) {
          'getUser' => <String, dynamic>{
            '@type': 'user',
            'id': 7,
            'profile_photo': {
              '@type': 'profilePhoto',
              'id': 70,
              'small': {'@type': 'file', 'id': 42},
            },
          },
          _ => <String, dynamic>{'@type': 'ok'},
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  tearDownAll(() => updates.close());

  ChatMessage message({int? senderId, TdFileRef? senderPhoto}) => ChatMessage(
    id: 1,
    isOutgoing: false,
    text: 'hi',
    date: 1,
    contentType: 'messageText',
    senderId: senderId,
    senderPhoto: senderPhoto,
  );

  test('a message hit resolves its author, not the chat photo', () async {
    final chatPhoto = TdFileRef(id: 99);
    final photo = await messageSenderPhoto(
      message(senderId: 7),
      chatPhoto: chatPhoto,
    );
    expect(photo?.id, 42);
    expect(photo?.photoId, 70);
  });

  test('an already-resolved sender photo needs no request', () async {
    final own = TdFileRef(id: 5);
    expect(
      (await messageSenderPhoto(
        message(senderId: 7, senderPhoto: own),
        chatPhoto: TdFileRef(id: 99),
      ))?.id,
      5,
    );
  });

  test('a message without an author keeps the chat photo', () async {
    final chatPhoto = TdFileRef(id: 99);
    expect((await messageSenderPhoto(message(), chatPhoto: chatPhoto))?.id, 99);
  });
}
