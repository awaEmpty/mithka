import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../tdlib/json_helpers.dart' show TdJson, jsonInt;
import '../tdlib/td_client.dart';
import 'ios_communication_notification.dart';
import 'notification_controller.dart';
import 'notification_preferences.dart';
import 'push_service_settings.dart';
import 'unified_push_credentials.dart';

/// Builds the DeviceToken variant TDLib expects for a platform, or null on a
/// platform with no push transport.
@visibleForTesting
Map<String, dynamic>? deviceTokenRequestFor({
  required String platform,
  required String token,
  required bool encrypt,
  required bool isAppSandbox,
}) {
  switch (platform) {
    case 'android':
      return {
        '@type': 'deviceTokenFirebaseCloudMessaging',
        'token': token,
        'encrypt': encrypt,
      };
    case 'ios':
      return {
        '@type': 'deviceTokenApplePush',
        'device_token': token,
        'is_app_sandbox': isAppSandbox,
      };
    default:
      return null;
  }
}

/// Extracts the Telegram push payload map out of an FCM message's `data`
/// without asserting on its shape: a non-Telegram FCM message (analytics,
/// crash reporter) is data the registrar never touches.
@visibleForTesting
Map<String, dynamic>? telegramPushPayloadFromFCMData(
  Map<String, dynamic>? data,
) {
  if (data == null) return null;
  // FCM delivers the whole payload JSON-encoded under "p" when it is too
  // large for the dictionary form.
  final outerPayload = data['p'];
  if (outerPayload is String && outerPayload.isNotEmpty) {
    try {
      final decoded = jsonDecode(outerPayload);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
  }
  if (data.containsKey('loc_key') || data.containsKey('custom')) {
    return data;
  }
  final nested = data['data'];
  if (nested is Map) {
    final inner = nested.map((key, value) => MapEntry(key.toString(), value));
    if (inner.containsKey('loc_key') || inner.containsKey('custom')) {
      return inner;
    }
  }
  return null;
}

/// Serializes registration work while remembering that inputs changed during
/// an in-flight pass. The queued pass observes the newest token/account policy.
@visibleForTesting
class PushRegistrationDrain {
  bool _running = false;
  bool _queued = false;

  bool get isRunning => _running;
  bool get isQueued => _queued;

  Future<void> run(Future<void> Function() operation) async {
    if (_running) {
      _queued = true;
      return;
    }
    _running = true;
    try {
      do {
        _queued = false;
        await operation();
      } while (_queued);
    } finally {
      _running = false;
    }
  }
}

class PushDeviceRegistrar {
  PushDeviceRegistrar._();
  static final PushDeviceRegistrar shared = PushDeviceRegistrar._();

  static const _channel = MethodChannel('mithka/push');
  static const _lastRegistrationKey = 'mithka.push.lastRegistration.v1';

  final TdClient _client = TdClient.shared;
  final NotificationPreferences _preferences = NotificationPreferences.shared;
  final PushServiceSettings _pushSettings = PushServiceSettings.shared;
  final PushServiceStatus _pushStatus = PushServiceStatus.shared;
  StreamSubscription? _sub;
  StreamSubscription<int>? _accountSub;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundMessageSub;
  String? _deviceToken;
  String? _lastRegistrationSignature;
  bool _running = false;
  bool _fcmStarted = false;
  bool _fcmBootstrapPending = false;
  Timer? _fcmRetryTimer;
  int _fcmRetryCount = 0;
  bool _fallbackKeepAlive = false;
  UnifiedPushCredentials? _unifiedCredentials;
  Map<String, dynamic>? _lastRegistrationRecord;
  SharedPreferences? _recordPreferences;
  final Map<int, int> _clientIdByReceiverId = {};
  final PushRegistrationDrain _registrationDrain = PushRegistrationDrain();

  /// Platform gate, replaced in tests so the Android branch runs on the host.
  @visibleForTesting
  String Function() debugPlatformName = () => Platform.isIOS
      ? 'ios'
      : Platform.isAndroid
      ? 'android'
      : 'other';

  /// FCM bootstrap, replaced in tests to avoid a live Firebase instance.
  @visibleForTesting
  Future<FCMBootstrap?> Function()? debugFCMBootstrap;

  /// Native bridge calls, replaced in tests to avoid a live MethodChannel.
  @visibleForTesting
  Future<Map<String, dynamic>?> Function(
    String method, [
    Map<String, dynamic>? arguments,
  ])?
  debugNativeCall;

  Future<void> start() async {
    if (_running) return;
    final platform = debugPlatformName();
    if (platform != 'ios' && platform != 'android') return;
    _running = true;
    await _pushSettings.ensureInitialized();
    _recordPreferences ??= await SharedPreferences.getInstance();
    _loadLastRegistrationRecord();
    _preferences.addListener(_preferencesChanged);
    _channel.setMethodCallHandler(_handleNativeMethod);
    if (platform == 'android') {
      _pushSettings.addListener(_pushSettingsChanged);
      _pushStatus.update(activeKind: _pushSettings.kind);
      await _applyNativePushMode();
      unawaited(_nativeCall('clearFallbackNotifications'));
      await _consumePendingNotificationTap();
    }
    _sub = _client.subscribe().listen(_handleTdUpdate);
    _accountSub = _client.subscribeActiveSlotChanges().listen((_) {
      if (_preferences.accountMode != NotificationAccountMode.current) return;
      _lastRegistrationSignature = null;
      unawaited(_registerIfPossible());
    });
    if (platform == 'ios') {
      try {
        final token = await _channel.invokeMethod<String>(
          'registerForRemoteNotifications',
        );
        _setDeviceToken(token);
      } catch (error) {
        debugPrint('APNs registration request failed: $error');
      }
    } else if (_pushSettings.kind == PushServiceKind.fcm ||
        _pushSettings.kind == PushServiceKind.microG) {
      unawaited(_bootstrapFCM());
    }
    unawaited(_registerIfPossible());
  }

  Future<Map<String, dynamic>?> _nativeCall(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final override = debugNativeCall;
    if (override != null) return override(method, arguments);
    try {
      return await _channel.invokeMapMethod<String, dynamic>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Native push bridge $method failed: $error');
      return null;
    }
  }

  Future<void> _applyNativePushMode() async {
    final status = await _nativeCall('applyPushService', {
      'mode': _pushSettings.kind.index,
      'gateway': _pushSettings.gateway,
      'resident': _pushSettings.residentNotification,
    });
    if (status != null) _pushStatus.updateFromNative(status);
    if (_pushSettings.kind == PushServiceKind.unifiedPush) {
      final registration = await _nativeCall('getUnifiedPushRegistration');
      _applyUnifiedPushRegistration(registration);
    } else {
      _unifiedCredentials = null;
    }
  }

  Future<void> _consumePendingNotificationTap() async {
    final result = await _nativeCall('consumeNotificationTap');
    final payload = result?['payload'];
    if (payload is String && payload.isNotEmpty) {
      NotificationController.shared.openPayload(payload);
    }
  }

  void _loadLastRegistrationRecord() {
    final raw = _recordPreferences?.getString(_lastRegistrationKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _lastRegistrationRecord = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {}
  }

  Future<void> _saveLastRegistrationRecord(Map<String, dynamic> record) async {
    _lastRegistrationRecord = record;
    await _recordPreferences?.setString(
      _lastRegistrationKey,
      jsonEncode(record),
    );
  }

  Future<void> _clearLastRegistrationRecord() async {
    _lastRegistrationRecord = null;
    await _recordPreferences?.remove(_lastRegistrationKey);
  }

  void _pushSettingsChanged() {
    _lastRegistrationSignature = null;
    _pushStatus.update(activeKind: _pushSettings.kind, clearError: true);
    unawaited(_applyNativePushMode());
    final kind = _pushSettings.kind;
    if (kind == PushServiceKind.fcm || kind == PushServiceKind.microG) {
      unawaited(_bootstrapFCM());
    } else {
      unawaited(_tokenRefreshSub?.cancel());
      _tokenRefreshSub = null;
      unawaited(_foregroundMessageSub?.cancel());
      _foregroundMessageSub = null;
      _fcmStarted = false;
      _fcmRetryTimer?.cancel();
      _fcmRetryTimer = null;
      _fcmRetryCount = 0;
    }
    if (kind != PushServiceKind.unifiedPush) {
      _unifiedCredentials = null;
    }
    unawaited(_registerIfPossible());
  }

  Future<void> retry() async {
    _lastRegistrationSignature = null;
    _fcmRetryCount = 0;
    _fcmStarted = false;
    _pushStatus.update(clearError: true);
    await _applyNativePushMode();
    final kind = _pushSettings.kind;
    if (kind == PushServiceKind.fcm || kind == PushServiceKind.microG) {
      await _bootstrapFCM();
    }
    await _registerIfPossible();
  }

  Future<void> _bootstrapFCM() async {
    if (_fcmStarted) return;
    if (_pushSettings.kind != PushServiceKind.fcm &&
        _pushSettings.kind != PushServiceKind.microG) {
      return;
    }
    _fcmRetryTimer?.cancel();
    _fcmStarted = true;
    _fcmBootstrapPending = true;
    FCMBootstrap? bootstrap;
    try {
      bootstrap = await (debugFCMBootstrap?.call() ?? _liveFCMBootstrap());
    } finally {
      _fcmBootstrapPending = false;
    }
    if (bootstrap == null) {
      _fcmStarted = false;
      debugPrint('FCM registration skipped: no usable token');
      _pushStatus.update(error: 'fcm_unavailable');
      await _setFallbackKeepAlive(true);
      unawaited(_registerIfPossible());
      _scheduleFCMRetry();
      return;
    }
    _fcmRetryCount = 0;
    _setDeviceToken(bootstrap.initialToken);
    unawaited(_registerIfPossible());
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = bootstrap.tokenRefresh.listen((token) {
      _setDeviceToken(token);
      unawaited(_registerIfPossible());
    });
    await _foregroundMessageSub?.cancel();
    _foregroundMessageSub = bootstrap.foregroundMessages.listen(
      _handleFCMForegroundMessage,
    );
  }

  /// Retries a failed token fetch while the user still has FCM/microG
  /// selected. microG can take a few seconds after boot to bind its GMS
  /// service; a single early getToken() failure must not pin the settings
  /// screen to "unavailable" for the rest of the process.
  void _scheduleFCMRetry() {
    if (_fcmRetryCount >= 5) return;
    if (_pushSettings.kind != PushServiceKind.fcm &&
        _pushSettings.kind != PushServiceKind.microG) {
      return;
    }
    _fcmRetryCount++;
    _fcmRetryTimer?.cancel();
    _fcmRetryTimer = Timer(const Duration(seconds: 20), () {
      if (_pushSettings.kind != PushServiceKind.fcm &&
          _pushSettings.kind != PushServiceKind.microG) {
        return;
      }
      unawaited(_bootstrapFCM());
    });
  }

  Future<FCMBootstrap?> _liveFCMBootstrap() async {
    try {
      // Do not wait for main's idle telemetry task: it can be delayed for
      // longer than any sensible registration timeout on a cold start. When
      // the native google-services config exists, initialize without explicit
      // options so FlutterFire adopts FirebaseInitProvider's [DEFAULT] app
      // (passing the hardcoded options here throws "already exists").
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp().timeout(const Duration(seconds: 15));
      }
      if (Firebase.apps.isEmpty) {
        debugPrint('FCM registration skipped: Firebase has no default app');
        return null;
      }
      // Token retrieval is independent of the POST_NOTIFICATIONS dialog; the
      // notification controller owns the permission prompt and this bootstrap
      // must not block behind it.
      final token = await FirebaseMessaging.instance.getToken().timeout(
        const Duration(seconds: 15),
      );
      if (token == null || token.trim().isEmpty) {
        debugPrint('FCM registration skipped: empty device token');
        return null;
      }
      return FCMBootstrap(
        initialToken: token,
        tokenRefresh: FirebaseMessaging.instance.onTokenRefresh,
        foregroundMessages: FirebaseMessaging.onMessage,
      );
    } on TimeoutException catch (error) {
      debugPrint('FCM registration timed out: $error');
      return null;
    } catch (error) {
      debugPrint('FCM registration failed: $error');
      return null;
    }
  }

  void _handleFCMForegroundMessage(RemoteMessage message) {
    final payload = telegramPushPayloadFromFCMData(message.data);
    if (payload == null) return;
    unawaited(_processPush(payload));
  }

  /// Routes a Telegram FCM payload to the account that owns it. Telegram's
  /// payload carries a `user_id` naming the receiving account, and a multi-
  /// account client must not feed account A's push into account B's TDLib.
  Future<void> _processPush(Map<String, dynamic> payload) => _processPushJson(
    jsonEncode(payload),
    payloadUserId: jsonInt(payload['user_id']),
  );

  /// Handles a push payload that already arrived as JSON — FCM data, the
  /// UnifiedPush bridge's decrypted `{"p": ...}` body, or a plaintext simple
  /// push. TDLib's `processPushNotification` accepts the payload verbatim and
  /// performs any additional decryption it asked the server for.
  Future<void> _processPushJson(String payload, {int? payloadUserId}) async {
    if (payload.trim().isEmpty) return;
    final targetClientId =
        _clientIdForPushReceiver(payload) ??
        _clientIdForPushUserId(payloadUserId) ??
        _clientIdForPushUserId(_userIdInsidePayload(payload));
    final request = {'@type': 'processPushNotification', 'payload': payload};
    try {
      if (targetClientId != null) {
        await _client.queryTo(request, targetClientId);
      } else {
        await _client.query(request);
      }
    } catch (error) {
      debugPrint('processPushNotification failed: $error');
    }
  }

  int? _userIdInsidePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final custom = decoded['custom'];
      return jsonInt(decoded['user_id']) ??
          jsonInt(custom is Map ? custom['user_id'] : null);
    } catch (_) {
      return null;
    }
  }

  int? _clientIdForPushReceiver(String payload) {
    if (_clientIdByReceiverId.isEmpty) return null;
    try {
      final result = _client.execute({
        '@type': 'getPushReceiverId',
        'payload': payload,
      });
      final receiverId = jsonInt(result?['id']);
      if (receiverId == null || receiverId == 0) return null;
      return _clientIdByReceiverId[receiverId];
    } catch (_) {}
    return null;
  }

  int? _clientIdForPushUserId(int? userId) {
    if (userId == null) return null;
    for (final entry in _knownUserIdsByClient.entries) {
      if (entry.value == userId) return entry.key;
    }
    return null;
  }

  /// accountId → userId, filled by each registration pass so push routing can
  /// pick the owning TDLib client without another getMe round trip.
  final Map<int, int> _knownUserIdsByClient = {};

  void _preferencesChanged() {
    _lastRegistrationSignature = null;
    unawaited(_registerIfPossible());
  }

  Future<dynamic> _handleNativeMethod(MethodCall call) async {
    switch (call.method) {
      case 'deviceToken':
        _setDeviceToken(call.arguments as String?);
        unawaited(_registerIfPossible());
      case 'registrationError':
        debugPrint('APNs registration failed: ${call.arguments}');
      case 'pushPayload':
        final payload = call.arguments;
        if (payload is String) {
          unawaited(_processPushJson(payload));
        } else if (payload is Map) {
          unawaited(
            _processPush(
              payload.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      case 'unifiedPushRegistration':
        _applyUnifiedPushRegistration(call.arguments);
      case 'pushStatus':
        final status = call.arguments;
        if (status is Map) {
          _pushStatus.updateFromNative(
            status.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
      case 'pushWake':
        unawaited(_wakeAccounts());
      case 'notificationTap':
        final payload = call.arguments;
        if (payload is String && payload.isNotEmpty) {
          NotificationController.shared.openPayload(payload);
        }
    }
  }

  void _applyUnifiedPushRegistration(Object? value) {
    final credentials = UnifiedPushCredentials.fromMap(value);
    _unifiedCredentials = credentials;
    if (credentials == null) {
      _pushStatus.update(
        clearEndpoint: true,
        registered: false,
        keepAlive:
            _fallbackKeepAlive || _pushSettings.kind == PushServiceKind.inApp,
      );
      return;
    }
    _lastRegistrationSignature = null;
    _pushStatus.update(
      distributor: credentials.distributor,
      endpoint: credentials.endpoint,
      clearError: true,
    );
    unawaited(_registerIfPossible());
  }

  Future<void> _wakeAccounts() async {
    for (final clientId in _client.registeredClientIds.toList()) {
      try {
        // Any query resumes a suspended TDLib connection.
        await _client.queryTo(
          {'@type': 'getOption', 'name': 'version'},
          clientId,
          timeout: const Duration(seconds: 5),
        );
      } catch (_) {}
    }
  }

  void _handleTdUpdate(Map<String, dynamic> update) {
    if (update.type != 'updateAuthorizationState') return;
    final state = update.obj('authorization_state');
    if (state?.type == 'authorizationStateReady') {
      unawaited(_registerIfPossible());
    }
  }

  void _setDeviceToken(String? token) {
    final normalized = token?.trim();
    if (normalized == null || normalized.isEmpty) return;
    if (_deviceToken == normalized) return;
    _deviceToken = normalized;
    _lastRegistrationSignature = null;
  }

  Future<void> _registerIfPossible() =>
      _registrationDrain.run(_registerOnceIfPossible);

  Future<void> _registerOnceIfPossible() async {
    if (!_running) return;
    final kind = debugPlatformName() == 'android'
        ? _pushSettings.kind
        : PushServiceKind.fcm;
    try {
      final readyUsersByClient = await _readyUsersByClient();
      final usersByClient = <int, int>{
        for (final entry in readyUsersByClient.entries)
          if (_preferences.receivesNotificationsFrom(
            userId: entry.value,
            isActiveAccount: entry.key == _client.activeClientId,
          ))
            entry.key: entry.value,
      };
      if (usersByClient.isEmpty) return;
      final userIds = usersByClient.values.toSet().toList()..sort();
      _knownUserIdsByClient
        ..clear()
        ..addAll(usersByClient);

      final tokens = switch (kind) {
        PushServiceKind.inApp => <Map<String, dynamic>>[],
        PushServiceKind.unifiedPush =>
          _unifiedCredentials?.isComplete ?? false
              ? unifiedPushDeviceTokens(_unifiedCredentials!)
              : null,
        PushServiceKind.fcm || PushServiceKind.microG =>
          _deviceToken == null
              ? null
              : [
                  deviceTokenRequestFor(
                    platform: debugPlatformName(),
                    token: _deviceToken!,
                    encrypt: false,
                    isAppSandbox: kDebugMode,
                  )!,
                ],
      };
      if (tokens == null) {
        if (debugPlatformName() == 'android') {
          // The FCM token request has not finished yet. Marking the transport
          // unavailable here would flash (or pin) an error before getToken()
          // has had a chance to return; wait for the bootstrap result instead.
          if ((kind == PushServiceKind.fcm || kind == PushServiceKind.microG) &&
              _fcmBootstrapPending) {
            _pushStatus.update(clearError: true);
            return;
          }
          // The chosen transport has nothing to register yet. Do not leave a
          // previous transport's subscription alive next to it; a stale FCM
          // token plus a UnifiedPush endpoint double-posts every message.
          await _deregisterPrevious(usersByClient);
          _pushStatus.update(
            error: kind == PushServiceKind.unifiedPush
                ? 'unified_unavailable'
                : 'fcm_unavailable',
          );
          await _setFallbackKeepAlive(true);
        }
        return;
      }

      final signature =
          '$kind|${jsonEncode(tokens)}|$kDebugMode|${userIds.join(',')}';
      if (_lastRegistrationSignature == signature) return;
      if (tokens.isEmpty) {
        await _deregisterPrevious(usersByClient);
        _lastRegistrationSignature = signature;
        _pushStatus.update(
          registered: false,
          keepAlive: true,
          clearError: true,
        );
        await _setFallbackKeepAlive(false);
        await _saveLastRegistrationRecord({
          'kind': kind.name,
          'tokens': const <Map<String, dynamic>>[],
        });
        return;
      }

      await _deregisterPrevious(
        usersByClient,
        unlessSignature: '$kind|${jsonEncode(tokens)}',
      );
      _clientIdByReceiverId.clear();
      for (final entry in usersByClient.entries) {
        final otherUserIds = userIds
            .where((userId) => userId != entry.value)
            .toList(growable: false);
        for (final token in tokens) {
          final result = await _client.queryTo(
            {
              '@type': 'registerDevice',
              'device_token': token,
              'other_user_ids': otherUserIds,
            },
            entry.key,
            timeout: const Duration(seconds: 8),
          );
          final receiverId = jsonInt(result['id']);
          if (receiverId != null) {
            _clientIdByReceiverId[receiverId] = entry.key;
          }
        }
      }
      _lastRegistrationSignature = signature;
      await _saveLastRegistrationRecord({'kind': kind.name, 'tokens': tokens});
      await _setFallbackKeepAlive(false);
      _pushStatus.update(registered: true, keepAlive: false, clearError: true);
      // The service extension stamps the slot onto a delivered push, so it
      // needs the mapping before the next one arrives rather than at tap time.
      await _publishAccountSlots(usersByClient);
      debugPrint('Registered $kind push device token with TDLib');
    } catch (error) {
      debugPrint('TDLib push device registration failed: $error');
      _pushStatus.update(error: 'registration_failed');
    }
  }

  /// Removes whatever transport was registered in an earlier run (or earlier
  /// in this one) before a different token takes its place.
  Future<void> _deregisterPrevious(
    Map<int, int> usersByClient, {
    String? unlessSignature,
  }) async {
    final record = _lastRegistrationRecord;
    if (record == null) return;
    final previousTokens = record['tokens'];
    if (previousTokens is! List || previousTokens.isEmpty) return;
    final previousSignature = '${record['kind']}|${jsonEncode(previousTokens)}';
    if (unlessSignature != null && previousSignature == unlessSignature) {
      return;
    }
    final userIds = usersByClient.values.toSet().toList()..sort();
    for (final entry in usersByClient.entries) {
      final otherUserIds = userIds
          .where((userId) => userId != entry.value)
          .toList(growable: false);
      for (final rawToken in previousTokens) {
        if (rawToken is! Map) continue;
        final token = rawToken.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final empty = _emptyDeviceToken(token);
        if (empty == null) continue;
        try {
          await _client.queryTo(
            {
              '@type': 'registerDevice',
              'device_token': empty,
              'other_user_ids': otherUserIds,
            },
            entry.key,
            timeout: const Duration(seconds: 8),
          );
        } catch (error) {
          debugPrint('Push deregistration failed: $error');
        }
      }
    }
    await _clearLastRegistrationRecord();
  }

  Map<String, dynamic>? _emptyDeviceToken(Map<String, dynamic> token) {
    switch (token['@type']) {
      case 'deviceTokenFirebaseCloudMessaging':
        return {...token, 'token': ''};
      case 'deviceTokenWebPush':
        return {
          ...token,
          'endpoint': '',
          'p256dh_base64url': '',
          'auth_base64url': '',
        };
      case 'deviceTokenSimplePush':
        return {...token, 'endpoint': ''};
      default:
        return null;
    }
  }

  Future<void> _setFallbackKeepAlive(bool enabled) async {
    if (debugPlatformName() != 'android') return;
    if (_pushSettings.kind == PushServiceKind.inApp) return;
    if (_fallbackKeepAlive == enabled) return;
    _fallbackKeepAlive = enabled;
    await _nativeCall('setKeepAlive', {'enabled': enabled});
    _pushStatus.update(keepAlive: enabled);
  }

  Future<void> _publishAccountSlots(Map<int, int> usersByClient) async {
    if (!Platform.isIOS) return;
    final slotsByUserId = <int, int>{};
    for (final entry in usersByClient.entries) {
      final slot = _client.slotForClient(entry.key);
      if (slot != null) slotsByUserId[entry.value] = slot;
    }
    try {
      await const IOSCommunicationNotificationBridge().setAccountSlots(
        slotsByUserId,
      );
    } catch (error) {
      debugPrint('Publishing notification account slots failed: $error');
    }
  }

  Future<Map<int, int>> _readyUsersByClient() async {
    final usersByClient = <int, int>{};
    for (final slot in _client.configuredSlots) {
      final clientId = _client.clientId(slot);
      if (clientId == null) continue;
      try {
        final state = await _client.queryTo(
          {'@type': 'getAuthorizationState'},
          clientId,
          timeout: const Duration(seconds: 2),
        );
        if (state.type != 'authorizationStateReady') continue;
        final me = await _client.queryTo(
          {'@type': 'getMe'},
          clientId,
          timeout: const Duration(seconds: 3),
        );
        final userId = me.int64('id');
        if (userId != null) usersByClient[clientId] = userId;
      } catch (_) {
        continue;
      }
    }
    return usersByClient;
  }

  Future<void> stop() async {
    _preferences.removeListener(_preferencesChanged);
    _pushSettings.removeListener(_pushSettingsChanged);
    await _sub?.cancel();
    _sub = null;
    await _accountSub?.cancel();
    _accountSub = null;
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    await _foregroundMessageSub?.cancel();
    _foregroundMessageSub = null;
    _fcmRetryTimer?.cancel();
    _fcmRetryTimer = null;
    _fcmRetryCount = 0;
    _fcmBootstrapPending = false;
    _running = false;
    _fcmStarted = false;
  }
}

/// The FCM surface [PushDeviceRegistrar] needs, mirrored by tests.
class FCMBootstrap {
  const FCMBootstrap({
    required this.initialToken,
    required this.tokenRefresh,
    required this.foregroundMessages,
  });

  final String? initialToken;
  final Stream<String> tokenRefresh;
  final Stream<RemoteMessage> foregroundMessages;
}
