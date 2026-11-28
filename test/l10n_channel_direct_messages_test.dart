//
//  l10n_channel_direct_messages_test.dart
//
//  The channel header's direct-messages row used to stay English in every
//  locale, and the whole direct-message topic family shipped with the English
//  source values in all seven translations.
//

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _locales = [
  'de-DE',
  'es-ES',
  'fr-FR',
  'ja-JP',
  'ko-KR',
  'zh-Hans-CN',
  'zh-Hant-TW',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, String>> catalogue(String tag) async {
    final raw = await rootBundle.loadString('assets/l10n/$tag.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (json['strings'] as Map<String, dynamic>).cast<String, String>();
  }

  test('the direct-messages row is translated in every locale', () async {
    expect((await catalogue('zh-Hans-CN'))['channelDirectMessages'], '频道私聊');
    expect((await catalogue('zh-Hant-TW'))['channelDirectMessages'], '頻道私聊');
    expect(
      (await catalogue('de-DE'))['channelDirectMessages'],
      'Kanal-Direktnachrichten',
    );
    expect(
      (await catalogue('es-ES'))['channelDirectMessages'],
      'Mensajes directos del canal',
    );
    expect(
      (await catalogue('fr-FR'))['channelDirectMessages'],
      'Messages privés de la chaîne',
    );
    expect(
      (await catalogue('ja-JP'))['channelDirectMessages'],
      'チャンネルのダイレクトメッセージ',
    );
    expect((await catalogue('ko-KR'))['channelDirectMessages'], '채널 다이렉트 메시지');
    expect(
      (await catalogue('en-US'))['channelDirectMessages'],
      'Channel Direct Messages',
    );
  });

  test('no direct-message topic string is left in English', () async {
    final source = await catalogue('en-US');
    final keys = source.keys
        .where((key) => key.startsWith('channelDirectMessages'))
        .toList();
    expect(keys.length, greaterThanOrEqualTo(30));
    for (final locale in _locales) {
      final translated = await catalogue(locale);
      final untranslated = [
        for (final key in keys)
          if (translated[key] == source[key]) key,
      ];
      expect(
        untranslated,
        isEmpty,
        reason: '$locale still carries the English source for $untranslated',
      );
    }
  });

  test('the payment and topic dialogs read naturally in Chinese', () async {
    final zh = await catalogue('zh-Hans-CN');
    expect(zh['channelDirectMessagesAllowAndRefund'], '允许并退款');
    expect(zh['channelDirectMessagesClear'], '清空话题历史');
    expect(zh['channelDirectMessagesRefundTitle'], '退还此前的付款？');
    expect(zh['channelDirectMessagesRevenue'], '已收到 {value1} 星');
    expect(zh['channelDirectMessagesUnpinAll'], '取消置顶所有消息');
  });
}
