//
//  media_prefetch_test.dart
//
//  A prefetch is only allowed to fetch what the current network's
//  auto-download preset allows, must not repeat itself, and must treat an
//  unknown size as "let the visible row ask".
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/media/media_prefetch.dart';
import 'package:mithka/settings/downloads_storage/auto_download_media_controller.dart';
import 'package:mithka/tdlib/td_models.dart';

TdFileRef _file(int id, int size) => TdFileRef(id: id, size: size);

PrefetchCandidate _photo(int id, int size) =>
    PrefetchCandidate(file: _file(id, size), kind: PrefetchMediaKind.photo);

void main() {
  late List<int> downloads;

  MediaPrefetch build({
    AutoDownloadProfile mobile = const AutoDownloadProfile.medium(),
    AutoDownloadProfile wifi = const AutoDownloadProfile.high(),
    PrefetchNetwork network = PrefetchNetwork.wifi,
  }) {
    downloads = <int>[];
    return MediaPrefetch(
      download: (id) async {
        downloads.add(id);
        return true;
      },
      mobileProfile: () => mobile,
      wifiProfile: () => wifi,
      networkProbe: () async => network,
      allowsKind: (_) => true,
    );
  }

  test('a photo inside the preset is fetched once', () async {
    final prefetch = build();
    final candidates = [_photo(11, 900 * 1024)];
    expect(await prefetch.prefetch(candidates), 1);
    expect(downloads, [11]);
    // The same file twice in one session is one download.
    expect(await prefetch.prefetch(candidates), 0);
    expect(downloads, [11]);
  });

  test('a photo over the preset limit is left to the visible row', () async {
    final prefetch = build(wifi: const AutoDownloadProfile.medium());
    expect(await prefetch.prefetch([_photo(12, 9 * 1024 * 1024)]), 0);
    expect(downloads, isEmpty);
  });

  test('a disabled preset prefetches nothing at all', () async {
    final prefetch = build(wifi: const AutoDownloadProfile.low());
    expect(await prefetch.prefetch([_photo(13, 1024)]), 0);
    expect(downloads, isEmpty);
  });

  test('the mobile preset is used on a metered link', () async {
    final prefetch = build(network: PrefetchNetwork.mobile);
    // 9 MB fits the wifi preset (20 MB) but not the mobile one (5 MB).
    expect(await prefetch.prefetch([_photo(14, 9 * 1024 * 1024)]), 0);
    expect(downloads, isEmpty);
  });

  test('an unknown size is never guessed', () async {
    final prefetch = build();
    expect(await prefetch.prefetch([_photo(15, 0)]), 0);
    expect(downloads, isEmpty);
  });

  test('a rejected download stays retryable', () async {
    var attempts = 0;
    final prefetch = MediaPrefetch(
      download: (id) async {
        attempts += 1;
        return attempts > 1;
      },
      mobileProfile: () => const AutoDownloadProfile.medium(),
      wifiProfile: () => const AutoDownloadProfile.high(),
      networkProbe: () async => PrefetchNetwork.wifi,
      allowsKind: (_) => true,
    );
    expect(await prefetch.prefetch([_photo(16, 1024)]), 0);
    expect(await prefetch.prefetch([_photo(16, 1024)]), 1);
    expect(attempts, 2);
  });

  test('content candidates read the same fields the mirror keeps', () {
    final candidates = MediaPrefetch.candidatesOfTdContent({
      '@type': 'messagePhoto',
      'caption': {'@type': 'formattedText', 'text': 'x'},
      'photo': {
        '@type': 'photo',
        'sizes': [
          {
            '@type': 'photoSize',
            'photo': {'@type': 'file', 'id': 21, 'size': 900},
          },
          {
            '@type': 'photoSize',
            'photo': {'@type': 'file', 'id': 22, 'size': 2048},
          },
        ],
      },
    });
    expect(candidates, hasLength(1));
    expect(
      candidates.single.fileId,
      22,
      reason: 'the largest size is the picture the snapshot wants',
    );
    expect(candidates.single.size, 2048);
  });

  test('a text message asks for nothing', () {
    expect(
      MediaPrefetch.candidatesOfTdContent({
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': 'hi'},
      }),
      isEmpty,
    );
  });
}
