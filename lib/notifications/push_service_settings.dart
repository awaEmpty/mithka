import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How Mithka receives push notifications.
///
/// The order matches the Android side (`PushServiceStore.MODE_*`) and
/// exteraless's Push Service Type selector, so the integer can cross the
/// method channel unchanged.
enum PushServiceKind { inApp, fcm, unifiedPush, microG }

extension PushServiceKindLabel on PushServiceKind {
  String get l10nKey => switch (this) {
    PushServiceKind.inApp => 'mithkaxPushServiceInApp',
    PushServiceKind.fcm => 'mithkaxPushServiceFcm',
    PushServiceKind.unifiedPush => 'mithkaxPushServiceUnified',
    PushServiceKind.microG => 'mithkaxPushServiceMicroG',
  };
}

/// The default UnifiedPush PUT-to-POST gateway. Telegram's WebPush sender
/// folds its Encryption/Crypto-Key headers into the body through this gateway
/// because UnifiedPush distributors forward only the body.
const kDefaultUnifiedPushGateway = 'https://p2p.belloworld.it/';

/// User-facing push delivery choices: which transport to use, the UnifiedPush
/// gateway, and whether the in-app keep-alive shows a resident notification.
///
/// Persisted separately from [NotificationPreferences] because the Android
/// side reads the same values before Dart exists (the keep-alive service and
/// the UnifiedPush service can start a cold process).
class PushServiceSettings extends ChangeNotifier {
  PushServiceSettings._();

  static final PushServiceSettings shared = PushServiceSettings._();

  static const _kindKey = 'mithka.push.kind.v1';
  static const _gatewayKey = 'mithka.push.unifiedGateway.v1';
  static const _residentKey = 'mithka.push.residentNotification.v1';

  SharedPreferences? _preferences;
  PushServiceKind _kind = PushServiceKind.fcm;
  String _gateway = kDefaultUnifiedPushGateway;
  bool _residentNotification = false;

  bool get isInitialized => _preferences != null;
  PushServiceKind get kind => _kind;
  bool get residentNotification => _residentNotification;

  /// The gateway normalized for building endpoint URLs: an explicit scheme,
  /// non-empty, one trailing slash.
  String get gateway {
    var trimmed = _gateway.trim();
    if (trimmed.isEmpty) trimmed = kDefaultUnifiedPushGateway;
    if (!trimmed.contains('://')) trimmed = 'https://$trimmed';
    return trimmed.endsWith('/') ? trimmed : '$trimmed/';
  }

  /// The value shown in the settings row, without the synthetic slash.
  String get gatewayDisplay => gateway;

  Future<void> ensureInitialized() async {
    if (_preferences != null) return;
    try {
      initialize(await SharedPreferences.getInstance());
    } catch (_) {
      // A platform without a preferences store (widget tests, early boot)
      // keeps the defaults; the registrar retries on its own start.
    }
  }

  void initialize(SharedPreferences preferences) {
    final wasInitialized = _preferences != null;
    final previousKind = _kind;
    final previousGateway = _gateway;
    final previousResident = _residentNotification;
    _preferences = preferences;
    final storedKind = preferences.getString(_kindKey);
    _kind = PushServiceKind.values.firstWhere(
      (kind) => kind.name == storedKind,
      orElse: () => PushServiceKind.fcm,
    );
    _gateway = preferences.getString(_gatewayKey) ?? kDefaultUnifiedPushGateway;
    _residentNotification = preferences.getBool(_residentKey) ?? false;
    if (wasInitialized &&
        (previousKind != _kind ||
            previousGateway != _gateway ||
            previousResident != _residentNotification)) {
      notifyListeners();
    }
  }

  Future<void> setKind(PushServiceKind value) async {
    if (value == _kind) return;
    _kind = value;
    notifyListeners();
    await _preferences?.setString(_kindKey, value.name);
  }

  Future<void> setGateway(String value) async {
    final normalized = value.trim().isEmpty
        ? kDefaultUnifiedPushGateway
        : value.trim();
    if (normalized == _gateway) return;
    _gateway = normalized;
    notifyListeners();
    await _preferences?.setString(_gatewayKey, normalized);
  }

  Future<void> setResidentNotification(bool value) async {
    if (value == _residentNotification) return;
    _residentNotification = value;
    notifyListeners();
    await _preferences?.setBool(_residentKey, value);
  }
}

/// Runtime state reported by the Android push bridge. Kept apart from the
/// persisted preferences so the settings screen can show what actually
/// happened (distributor missing, FCM unavailable, falling back to the
/// keep-alive service) without turning a failed registration into a failed
/// preference write.
class PushServiceStatus extends ChangeNotifier {
  PushServiceStatus._();

  static final PushServiceStatus shared = PushServiceStatus._();

  PushServiceKind _activeKind = PushServiceKind.fcm;
  String? _distributor;
  String? _endpoint;
  String? _error;
  bool _keepAlive = false;
  bool _registered = false;

  PushServiceKind get activeKind => _activeKind;
  String? get distributor => _distributor;
  String? get endpoint => _endpoint;
  String? get error => _error;
  bool get keepAlive => _keepAlive;
  bool get registered => _registered;

  void update({
    PushServiceKind? activeKind,
    String? distributor,
    String? endpoint,
    String? error,
    bool? keepAlive,
    bool? registered,
    bool clearError = false,
    bool clearEndpoint = false,
  }) {
    var changed = false;
    if (activeKind != null && activeKind != _activeKind) {
      _activeKind = activeKind;
      changed = true;
    }
    if (distributor != _distributor) {
      _distributor = distributor;
      changed = true;
    }
    if (clearEndpoint) {
      if (_endpoint != null) {
        _endpoint = null;
        changed = true;
      }
    } else if (endpoint != null && endpoint != _endpoint) {
      _endpoint = endpoint;
      changed = true;
    }
    if (clearError) {
      if (_error != null) {
        _error = null;
        changed = true;
      }
    } else if (error != _error) {
      _error = error;
      changed = true;
    }
    if (keepAlive != null && keepAlive != _keepAlive) {
      _keepAlive = keepAlive;
      changed = true;
    }
    if (registered != null && registered != _registered) {
      _registered = registered;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void updateFromNative(Map<String, dynamic> status) {
    final mode = status['mode'];
    final kind =
        mode is int && mode >= 0 && mode < PushServiceKind.values.length
        ? PushServiceKind.values[mode]
        : null;
    update(
      activeKind: kind,
      distributor: status['distributor'] as String?,
      endpoint: status['endpoint'] as String?,
      error: status['error'] as String?,
      keepAlive: status['keepAlive'] as bool?,
      registered: status['registered'] as bool?,
      clearEndpoint: status['endpoint'] == null,
      clearError: status['error'] == null,
    );
  }
}
