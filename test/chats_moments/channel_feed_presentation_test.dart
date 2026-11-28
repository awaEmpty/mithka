//
//  Channel feed presentation: the banner's two layers must cover the same
//  rect, and a post must have a body before the feed draws a card for it.
//

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/moments/moments_view.dart';
import 'package:mithka/tdlib/td_bindings.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channelId = -100500;

Map<String, dynamic> _base(int id, int date, Map<String, dynamic> content) => {
  '@type': 'message',
  'id': id,
  'chat_id': _channelId,
  'date': date,
  'is_outgoing': false,
  'is_channel_post': true,
  'sender_id': {'@type': 'messageSenderChat', 'chat_id': _channelId},
  'content': content,
};

Map<String, dynamic> _text(int id, int date, String text) => _base(id, date, {
  '@type': 'messageText',
  'text': {
    '@type': 'formattedText',
    'text': text,
    'entities': <Map<String, dynamic>>[],
  },
});

Map<String, dynamic> _service(int id, int date, String type) =>
    _base(id, date, {'@type': type, 'title': 'Renamed'});

Map<String, dynamic> _content(int id, int date, String type) =>
    _base(id, date, {'@type': type});

class _FakeBindings implements TdBindings {
  @override
  int createClientId() => 7;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> history;
  late Directory supportDir;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('mithka-channel-feed');
    addTearDown(() {
      if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    TdClient.shared.prepareForTesting(
      prefs: prefs,
      supportDir: supportDir.path,
      bindings: _FakeBindings(),
      queryOverride: (request, clientId) async {
        switch (request['@type']) {
          case 'getChatHistory':
            final from = request['from_message_id'] as int;
            return {
              '@type': 'messages',
              'messages': history.reversed
                  .where((m) => from == 0 || (m['id'] as int) <= from)
                  .take(request['limit'] as int)
                  .toList(),
            };
          case 'getMe':
            return {'@type': 'user', 'id': 42, 'first_name': 'Me'};
          case 'getChatMember':
            return {
              '@type': 'chatMember',
              'status': {'@type': 'chatMemberStatusMember'},
            };
          case 'getMessageProperties':
            return {
              '@type': 'messageProperties',
              'can_get_message_thread': false,
            };
        }
        return {'@type': 'ok'};
      },
    );
    final slot = TdClient.shared.addSlot();
    final clientId = TdClient.shared.clientId(slot);
    TdClient.shared.debugSetActiveAccountForTesting(slot, clientId ?? 0);
  });

  setUp(() {
    history = [
      _text(1, 1000, 'plain text post'),
      _content(2, 1200, 'messagePoll'),
      _content(3, 1300, 'messageVoiceNote'),
      _content(4, 1400, 'messageLocation'),
      _service(5, 1500, 'messageChatChangePhoto'),
      _service(6, 1600, 'messageChatChangeTitle'),
      _text(7, 2000, 'newest text'),
    ];
  });

  ChatSummary channel() => ChatSummary(
    id: _channelId,
    title: 'Mithka X',
    lastMessage: '',
    lastMessageId: 7,
    date: 2000,
    unreadCount: 0,
    order: 0,
    isMuted: true,
    kind: ChatKind.channel,
    photo: TdFileRef(id: 900),
  );

  Future<void> pumpFeed(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChannelMomentsView(channel: channel()),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('the banner blur is clipped to the banner band', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpFeed(tester);

    final blur = find.byWidgetPredicate(
      (widget) =>
          widget is ImageFiltered &&
          widget.imageFilter.toString().contains('blur'),
    );
    expect(blur, findsOneWidget);

    // The blurred photo spreads ~3σ past its box and ImageFiltered does not
    // clip, so without a ClipRect the blur painted past the band while the
    // 0.18 scrim stopped at it: the two top layers showed different heights.
    final clip = find.ancestor(of: blur, matching: find.byType(ClipRect)).first;
    expect(clip, findsOneWidget);
    final band = tester.getSize(clip);
    expect(band.height, 166);
    expect(band.width, 390);

    // TDImage parks a 3-minute download wait on an undelivered file update.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('service banners and body-less payloads never become posts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpFeed(tester);

    final rows = find.byType(ChannelPostRow);
    expect(rows, findsNWidgets(2));
    final ids = [
      for (var i = 0; i < rows.evaluate().length; i++)
        tester.widget<ChannelPostRow>(rows.at(i)).post.message.id,
    ];
    expect(ids, [7, 1]);

    // TDImage parks a 3-minute download wait on an undelivered file update.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  test('a post needs a body the feed row can paint', () {
    ChannelPost post(Map<String, dynamic> content) => ChannelPost(
      channel: channel(),
      message: TDParse.message(_base(1, 1000, content))!,
      accountSlot: 0,
    );

    expect(
      channelPostHasBody(
        post({
          '@type': 'messageText',
          'text': {
            '@type': 'formattedText',
            'text': 'text',
            'entities': <Map<String, dynamic>>[],
          },
        }),
      ),
      isTrue,
    );
    // The row draws no poll, voice note or location, and a service banner is
    // not a post at all.
    expect(channelPostHasBody(post({'@type': 'messagePoll'})), isFalse);
    expect(channelPostHasBody(post({'@type': 'messageVoiceNote'})), isFalse);
    expect(
      channelPostHasBody(
        post({
          '@type': 'messageLocation',
          'location': {'@type': 'location', 'latitude': 1.0, 'longitude': 2.0},
        }),
      ),
      isFalse,
    );
    expect(
      channelPostHasBody(post({'@type': 'messageChatChangePhoto'})),
      isFalse,
    );
  });
}
