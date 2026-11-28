//
//  auto_download_chat_types_test.dart
//
//  Auto-download is gated twice: by the network's preset and by the chat-type
//  mask. The mask is the client's own (TDLib has no chat types), so it lives
//  in preferences and must survive a restart, exactly like the presets.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/settings/downloads_storage/auto_download_media_controller.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('every chat type is allowed out of the box', () {
    final controller = AutoDownloadMediaController.shared;
    for (final type in AutoDownloadChatType.values) {
      expect(controller.allowsChatType(type), isTrue, reason: type.name);
    }
  });

  test('turning a type off persists and survives a reload', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = AutoDownloadMediaController.shared;
    controller.initialize(prefs);
    await controller.setChatType(AutoDownloadChatType.groups, false);
    expect(controller.allowsChatType(AutoDownloadChatType.groups), isFalse);
    expect(
      prefs.getString('autoDownload.chatTypes'),
      isNot(contains('groups')),
    );

    final reloaded = AutoDownloadMediaController.shared..initialize(prefs);
    expect(reloaded.allowsChatType(AutoDownloadChatType.groups), isFalse);
    expect(reloaded.allowsChatType(AutoDownloadChatType.channels), isTrue);
    await reloaded.setChatType(AutoDownloadChatType.groups, true);
  });

  test('a chat kind maps onto its bucket', () {
    expect(
      AutoDownloadMediaController.chatTypeOf(ChatKind.privateChat),
      AutoDownloadChatType.privateChats,
    );
    expect(
      AutoDownloadMediaController.chatTypeOf(ChatKind.bot),
      AutoDownloadChatType.privateChats,
    );
    expect(
      AutoDownloadMediaController.chatTypeOf(ChatKind.group),
      AutoDownloadChatType.groups,
    );
    expect(
      AutoDownloadMediaController.chatTypeOf(ChatKind.channel),
      AutoDownloadChatType.channels,
    );
  });

  test('an unknown kind needs a ticked bucket and an enabled preset', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = AutoDownloadMediaController.shared..initialize(prefs);
    // The presets ship the reference client's defaults: medium on mobile,
    // high on Wi-Fi, off while roaming.
    expect(controller.allowsAutoDownloadForKind(null, wifi: true), isTrue);
    expect(
      controller.allowsAutoDownloadForKind(ChatKind.group, wifi: true),
      isTrue,
    );
    for (final type in AutoDownloadChatType.values) {
      await controller.setChatType(type, false);
    }
    expect(controller.chatTypes, isEmpty);
    expect(controller.allowsAutoDownloadForKind(null, wifi: true), isFalse);
    expect(
      controller.allowsAutoDownloadForKind(ChatKind.group, wifi: true),
      isFalse,
    );
    for (final type in AutoDownloadChatType.values) {
      await controller.setChatType(type, true);
    }
  });

  test('a disabled preset wins over any ticked type', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = AutoDownloadMediaController.shared..initialize(prefs);
    // Roaming is the low preset: auto-download off, whatever the mask says.
    expect(controller.allowsChatType(AutoDownloadChatType.groups), isTrue);
    expect(controller.allowsAutoDownload(AutoDownloadChatType.groups), isFalse);
    expect(controller.allowsAutoDownloadForKind(ChatKind.group), isFalse);
  });
}
