//
//  instant_view_loader.dart
//
//  Fetches a `webPageInstantView` for a URL and caches parsed pages. The
//  viewer talks to an [InstantViewSource] so widget tests can serve canned
//  pages without a TDLib client; production uses [TdInstantViewSource].
//

import 'dart:async';

import '../../tdlib/td_client.dart';
import 'instant_view_models.dart';

/// Raised when Telegram has no Instant View for a URL (or cannot build one).
class InstantViewUnavailable implements Exception {
  const InstantViewUnavailable(this.url, [this.cause]);

  final String url;
  final Object? cause;

  @override
  String toString() => 'Instant View unavailable for $url';
}

/// The transport seam behind the viewer.
abstract interface class InstantViewSource {
  /// Loads the page for [url]. Implementations should prefer the local copy
  /// and touch the network only when [onlyLocal] is false.
  Future<InstantViewPage> fetch(String url, {required bool onlyLocal});
}

/// TDLib-backed source. `getWebPageInstantView` answers from the local
/// database when `only_local` is set, which makes a preview's own Instant
/// View open without a round trip.
class TdInstantViewSource implements InstantViewSource {
  const TdInstantViewSource({this.accountSlot});

  final int? accountSlot;

  @override
  Future<InstantViewPage> fetch(String url, {required bool onlyLocal}) async {
    final Map<String, dynamic> response;
    try {
      response = await TdClient.shared.queryForSlot({
        '@type': 'getWebPageInstantView',
        'url': url,
        'only_local': onlyLocal,
      }, accountSlot ?? TdClient.shared.activeSlot);
    } catch (error) {
      throw InstantViewUnavailable(url, error);
    }
    final page = InstantViewPage.parse(response);
    if (page.isEmpty) throw InstantViewUnavailable(url);
    return page;
  }
}

/// Loads pages once per URL and keeps a small LRU of parsed articles so
/// re-opening a link is instant.
class InstantViewLoader {
  InstantViewLoader({required this.source, this.cacheSize = 16});

  factory InstantViewLoader.td({int? accountSlot}) =>
      InstantViewLoader(source: TdInstantViewSource(accountSlot: accountSlot));

  final InstantViewSource source;
  final int cacheSize;

  final Map<String, InstantViewPage> _cache = {};
  final Map<String, Future<InstantViewPage>> _inFlight = {};

  static String normalize(String url) {
    var value = url.trim();
    if (value.isEmpty) return value;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return value;
    value = uri.removeFragment().toString();
    while (value.endsWith('/') && value.length > 'https://x'.length) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// The locally cached page for [url], when this loader already fetched it.
  InstantViewPage? cached(String url) => _cache[normalize(url)];

  /// Loads [url], preferring the local TDLib copy and falling back to the
  /// network, then to the full Instant View. Throws [InstantViewUnavailable]
  /// when Telegram has no page for the URL.
  Future<InstantViewPage> load(String url) {
    final key = normalize(url);
    if (key.isEmpty) return Future.error(InstantViewUnavailable(url));
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _load(key).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<InstantViewPage> _load(String url) async {
    InstantViewPage? local;
    try {
      local = await source.fetch(url, onlyLocal: true);
    } catch (_) {
      local = null;
    }
    if (local != null && !local.isEmpty) {
      _remember(url, local);
      return local;
    }
    final page = await source.fetch(url, onlyLocal: false);
    _remember(url, page);
    return page;
  }

  void _remember(String key, InstantViewPage page) {
    _cache.remove(key);
    _cache[key] = page;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }
}
