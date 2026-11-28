import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/notifications/push_device_registrar.dart';
import 'package:mithka/notifications/push_service_settings.dart';
import 'package:mithka/notifications/unified_push_credentials.dart';
import 'package:mithka/tdlib/td_bindings.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBindings implements TdBindings {
  int _nextClientId = 900;

  @override
  int createClientId() => _nextClientId++;

  @override
  void send(int clientId, String request) {}

  @override
  String? receive(double timeout) => throw UnimplementedError();

  @override
  Object? receiveJson(double timeout) => throw UnimplementedError();

  @override
  String? execute(String request) => throw UnimplementedError();

  @override
  String exportSessionString(
    String sourcePath, {
    required int apiId,
    required bool testMode,
    required int userId,
  }) => throw UnimplementedError();

  @override
  void importSessionString(String sessionString, String destinationPath) {
    File(destinationPath).writeAsBytesSync(Uint8List.fromList(const [1]));
  }

  @override
  bool get supportsSessionStringBackup => true;

  @override
  bool get supportsTransferBoost => false;

  @override
  void configureTransferBoost({
    required int downloadChunkSize,
    required int downloadParallelism,
    required int uploadChunkSize,
    required int uploadParallelism,
  }) {}
}

Map<String, dynamic> _answerFor(Map<String, dynamic> request) {
  switch (request['@type']) {
    case 'getAuthorizationState':
      return {'@type': 'authorizationStateReady'};
    case 'getMe':
      return {'@type': 'user', 'id': '7041948142'};
    case 'registerDevice':
      return {'@type': 'pushReceiverId', 'id': '1'};
    default:
      return {'@type': 'ok'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('push service preferences persist and normalize the gateway', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = PushServiceSettings.shared;
    settings.initialize(prefs);

    expect(settings.kind, PushServiceKind.fcm);
    expect(settings.gateway, kDefaultUnifiedPushGateway);

    await settings.setKind(PushServiceKind.unifiedPush);
    await settings.setGateway('https://example.org');
    await settings.setResidentNotification(true);

    expect(prefs.getString('mithka.push.kind.v1'), 'unifiedPush');
    expect(settings.gateway, 'https://example.org/');
    expect(prefs.getBool('mithka.push.residentNotification.v1'), isTrue);

    // Back to defaults so later tests in this file start from FCM.
    await settings.setKind(PushServiceKind.fcm);
    await settings.setGateway(kDefaultUnifiedPushGateway);
    await settings.setResidentNotification(false);
  });

  test('unified push credentials build the two TDLib device tokens', () {
    const credentials = UnifiedPushCredentials(
      endpoint: 'https://gw.example/aesgcm?e=topic',
      p256dh: 'public-key',
      auth: 'auth-secret',
      simpleEndpoint: 'https://ntfy.example/topic',
      distributor: 'io.heckel.ntfy',
    );
    final tokens = unifiedPushDeviceTokens(credentials);
    expect(tokens, hasLength(2));
    expect(tokens.first['@type'], 'deviceTokenWebPush');
    expect(tokens.first['endpoint'], credentials.endpoint);
    expect(tokens.first['p256dh_base64url'], 'public-key');
    expect(tokens.first['auth_base64url'], 'auth-secret');
    expect(tokens.last['@type'], 'deviceTokenSimplePush');
    expect(tokens.last['endpoint'], credentials.simpleEndpoint);

    final cleared = unifiedPushDeregistrationTokens(credentials);
    expect(cleared.first['endpoint'], '');
    expect(cleared.last['endpoint'], '');

    expect(UnifiedPushCredentials.fromMap(tokens.first), isNull);
    expect(
      UnifiedPushCredentials.fromMap({
        'endpoint': credentials.endpoint,
        'p256dh': credentials.p256dh,
        'auth': credentials.auth,
        'simpleEndpoint': credentials.simpleEndpoint,
      })?.simpleEndpoint,
      credentials.simpleEndpoint,
    );
  });

  test('manual Android plugin registry includes firebase_messaging', () {
    final source = File(
      'android/app/src/main/kotlin/x/empty/mithka/MainActivity.kt',
    ).readAsStringSync();
    // The app registers plugins by hand instead of calling
    // GeneratedPluginRegistrant. Without this entry FirebaseMessaging's method
    // channel has no handler, so getToken() fails before it reaches FCM.
    expect(
      source,
      contains(
        'io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingPlugin',
      ),
    );
  });

  test('resident notification off removes the foreground notification', () {
    final source = File(
      'android/app/src/main/kotlin/x/empty/mithka/PushKeepAliveService.kt',
    ).readAsStringSync();
    expect(source, contains('if (!resident)'));
    expect(source, contains('stopForegroundCompat()'));
    expect(source, contains('isForeground = false'));
  });

  test(
    'fcm bootstrap does not report unavailable while the token is pending',
    () async {
      SharedPreferences.setMockInitialValues({'mithka.push.kind.v1': 'fcm'});
      final prefs = await SharedPreferences.getInstance();
      final supportDir = Directory.systemTemp.createTempSync('mithka_fcm_test');
      addTearDown(() {
        if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
      });

      final requests = <Map<String, dynamic>>[];
      TdClient.shared.prepareForTesting(
        prefs: prefs,
        supportDir: supportDir.path,
        bindings: _FakeBindings(),
        queryOverride: (request, clientId) async {
          requests.add(request);
          return _answerFor(request);
        },
      );
      final slot = TdClient.shared.addSlot();
      TdClient.shared.setActive(slot);

      final settings = PushServiceSettings.shared;
      settings.initialize(prefs);
      final status = PushServiceStatus.shared;
      status.update(
        clearError: true,
        clearEndpoint: true,
        registered: false,
        keepAlive: false,
      );
      final registrar = PushDeviceRegistrar.shared;
      registrar.debugPlatformName = () => 'android';
      registrar.debugNativeCall = (method, [arguments]) async => null;
      final token = Completer<FCMBootstrap?>();
      registrar.debugFCMBootstrap = () => token.future;
      addTearDown(() async {
        await registrar.stop();
        registrar.debugFCMBootstrap = null;
        registrar.debugNativeCall = null;
      });

      await registrar.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(status.error, isNot('fcm_unavailable'));

      token.complete(
        const FCMBootstrap(
          initialToken: 'fcm-token',
          tokenRefresh: Stream.empty(),
          foregroundMessages: Stream.empty(),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (status.registered) break;
      }
      expect(status.registered, isTrue);
      expect(
        requests.where(
          (request) =>
              request['@type'] == 'registerDevice' &&
              request['device_token']['@type'] ==
                  'deviceTokenFirebaseCloudMessaging',
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'unified push registers both tokens and in-app mode revokes them',
    () async {
      SharedPreferences.setMockInitialValues({
        'mithka.push.kind.v1': 'unifiedPush',
      });
      final prefs = await SharedPreferences.getInstance();
      final supportDir = Directory.systemTemp.createTempSync('mithka_up_test');
      addTearDown(() {
        if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
      });

      final requests = <Map<String, dynamic>>[];
      TdClient.shared.prepareForTesting(
        prefs: prefs,
        supportDir: supportDir.path,
        bindings: _FakeBindings(),
        queryOverride: (request, clientId) async {
          requests.add(request);
          return _answerFor(request);
        },
      );
      final slot = TdClient.shared.addSlot();
      TdClient.shared.setActive(slot);

      final registrar = PushDeviceRegistrar.shared;
      addTearDown(() async {
        await registrar.stop();
        registrar.debugNativeCall = null;
        PushServiceSettings.shared.initialize(prefs);
      });
      final settings = PushServiceSettings.shared;
      settings.initialize(prefs);
      registrar.debugPlatformName = () => 'android';
      final nativeModes = <int>[];
      registrar.debugNativeCall = (method, [arguments]) async {
        switch (method) {
          case 'applyPushService':
            final mode = arguments?['mode'];
            if (mode is int) nativeModes.add(mode);
            return {'mode': 2, 'keepAlive': false, 'error': null};
          case 'getUnifiedPushRegistration':
            return {
              'endpoint': 'https://gw.example/aesgcm?e=topic',
              'p256dh': 'public-key',
              'auth': 'auth-secret',
              'simpleEndpoint': 'https://ntfy.example/topic',
              'distributor': 'ntfy',
            };
          default:
            return null;
        }
      };
      await registrar.start();

      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (requests
            .where((request) => request['@type'] == 'registerDevice')
            .any(
              (request) =>
                  request['device_token']['@type'] == 'deviceTokenSimplePush',
            )) {
          break;
        }
      }

      final registrations = requests
          .where((request) => request['@type'] == 'registerDevice')
          .toList();
      final tokenTypes = registrations
          .map((request) => request['device_token']['@type'])
          .toSet();
      expect(tokenTypes, contains('deviceTokenWebPush'));
      expect(tokenTypes, contains('deviceTokenSimplePush'));
      // Let the pass persist its registration record before switching modes.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Switching to the in-app transport must revoke both UnifiedPush tokens,
      // otherwise Telegram keeps posting to the old endpoint forever.
      await settings.setKind(PushServiceKind.inApp);
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (requests
            .where((request) => request['@type'] == 'registerDevice')
            .any(
              (request) =>
                  request['device_token']['@type'] == 'deviceTokenWebPush' &&
                  request['device_token']['endpoint'] == '',
            )) {
          break;
        }
      }
      final cleared = requests.where(
        (request) =>
            request['@type'] == 'registerDevice' &&
            request['device_token']['@type'] == 'deviceTokenWebPush' &&
            request['device_token']['endpoint'] == '',
      );
      expect(cleared, isNotEmpty);
      expect(nativeModes, contains(PushServiceKind.inApp.index));
    },
  );
}
