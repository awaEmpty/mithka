/// One UnifiedPush registration as reported by the Android bridge.
///
/// [endpoint] is the URL registered with Telegram: the gateway's
/// `/aesgcm?e=<distributor endpoint>` route for WebPush, or the distributor
/// endpoint itself when a distributor forwards Telegram's WebPush payload
/// unchanged. [simpleEndpoint] is the wake-up companion token registered
/// alongside it (the gateway's simple-push route, or the raw ntfy endpoint).
class UnifiedPushCredentials {
  const UnifiedPushCredentials({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
    required this.simpleEndpoint,
    this.distributor,
  });

  final String endpoint;
  final String p256dh;
  final String auth;
  final String simpleEndpoint;
  final String? distributor;

  bool get isComplete =>
      endpoint.isNotEmpty &&
      p256dh.isNotEmpty &&
      auth.isNotEmpty &&
      simpleEndpoint.isNotEmpty;

  static UnifiedPushCredentials? fromMap(Object? value) {
    if (value is! Map) return null;
    final map = value.map((key, value) => MapEntry(key.toString(), value));
    final endpoint = map['endpoint']?.toString() ?? '';
    final p256dh = map['p256dh']?.toString() ?? '';
    final auth = map['auth']?.toString() ?? '';
    final simpleEndpoint = map['simpleEndpoint']?.toString() ?? '';
    if (endpoint.isEmpty || p256dh.isEmpty || auth.isEmpty) return null;
    return UnifiedPushCredentials(
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth,
      simpleEndpoint: simpleEndpoint.isEmpty ? endpoint : simpleEndpoint,
      distributor: map['distributor']?.toString(),
    );
  }

  Map<String, String> toMap() => {
    'endpoint': endpoint,
    'p256dh': p256dh,
    'auth': auth,
    'simpleEndpoint': simpleEndpoint,
    'distributor': ?distributor,
  };
}

/// The TDLib device-token variant for this registration: WebPush carries the
/// gateway endpoint plus the locally generated P-256 key, SimplePush the
/// wake-up endpoint Telegram POSTs alongside it.
List<Map<String, dynamic>> unifiedPushDeviceTokens(
  UnifiedPushCredentials credentials,
) => [
  {
    '@type': 'deviceTokenWebPush',
    'endpoint': credentials.endpoint,
    'p256dh_base64url': credentials.p256dh,
    'auth_base64url': credentials.auth,
  },
  {'@type': 'deviceTokenSimplePush', 'endpoint': credentials.simpleEndpoint},
];

/// Deregisters both UnifiedPush tokens. TDLib's device-token docs use an empty
/// endpoint as "remove this subscription".
List<Map<String, dynamic>> unifiedPushDeregistrationTokens(
  UnifiedPushCredentials credentials,
) => [
  {
    '@type': 'deviceTokenWebPush',
    'endpoint': '',
    'p256dh_base64url': '',
    'auth_base64url': '',
  },
  {'@type': 'deviceTokenSimplePush', 'endpoint': ''},
];
