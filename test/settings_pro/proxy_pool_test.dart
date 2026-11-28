//
//  proxy_pool_test.dart
//
//  The app-wide saved-proxy pool: every account reads one list, deletions
//  leave a tombstone so another account's TDLib copy cannot resurrect the row,
//  and re-adding the same endpoint clears that tombstone.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/settings/network_proxy/proxy_config.dart';

ProxyConfig _proxy({
  String server = 'proxy.example',
  int port = 1080,
  String password = 'pw',
}) => ProxyConfig(
  configured: true,
  enabled: false,
  type: 'socks5',
  server: server,
  port: port,
  username: 'user',
  password: password,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secure;

  setUp(() {
    secure = {};
    ProxyConfig.debugSecureRead = (key) async => secure[key];
    ProxyConfig.debugSecureWrite = (key, value) async {
      if (value == null) {
        secure.remove(key);
      } else {
        secure[key] = value;
      }
    };
  });

  tearDown(() {
    ProxyConfig.debugSecureRead = null;
    ProxyConfig.debugSecureWrite = null;
  });

  test('saves and reloads the shared entries', () async {
    final pool = await ProxyPool.load();
    expect(pool.entries, isEmpty);
    expect(pool.add(_proxy()), isTrue);
    expect(pool.add(_proxy()), isFalse, reason: 'same endpoint, same row');
    expect(pool.add(_proxy(port: 1081)), isTrue);
    await pool.save();

    final reloaded = await ProxyPool.load();
    expect(reloaded.entries.length, 2);
    expect(
      reloaded.entries.map((entry) => entry.port),
      containsAll(<int>[1080, 1081]),
    );
    expect(
      reloaded.entries.first.password,
      'pw',
      reason: 'credentials live in secure storage with the pool',
    );
  });

  test('a deletion tombstones the endpoint for every account', () async {
    final pool = await ProxyPool.load();
    final proxy = _proxy();
    pool.add(proxy);
    expect(pool.remove(proxy), isTrue);
    await pool.save();

    final reloaded = await ProxyPool.load();
    expect(reloaded.entries, isEmpty);
    expect(reloaded.isTombstoned(proxy), isTrue);
    // A different password is a different saved row, not a resurrection.
    expect(reloaded.isTombstoned(_proxy(password: 'other')), isFalse);
    // Re-adding the endpoint clears its tombstone.
    expect(reloaded.add(proxy), isTrue);
    expect(reloaded.isTombstoned(proxy), isFalse);
    expect(reloaded.entries, hasLength(1));
  });

  test('an endpoint identity ignores the live enabled flag', () {
    final a = _proxy();
    final b = ProxyConfig(
      configured: true,
      enabled: true,
      type: a.type,
      server: a.server,
      port: a.port,
      username: a.username,
      password: a.password,
    );
    expect(ProxyPool.signatureFor(a), ProxyPool.signatureFor(b));
  });

  test('a corrupt or missing payload reads as an empty pool', () async {
    secure['mithka.proxy.pool.v2'] = '{not json';
    expect((await ProxyPool.load()).entries, isEmpty);
    secure.remove('mithka.proxy.pool.v2');
    expect((await ProxyPool.load()).entries, isEmpty);
  });
}
