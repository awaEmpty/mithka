//
//  update_prerelease_test.dart
//
//  About's update check offers pre-release builds only when the user opts in;
//  the shipped default is official releases only. A draft never counts, and
//  with the opt-in on the newest entry — pre-release or not — wins.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/update/release_feed.dart';

String _release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  List<Map<String, dynamic>> assets = const [],
}) =>
    '{"tag_name": "$tag", "prerelease": $prerelease, "draft": $draft, '
    '"assets": ${assets.isEmpty ? '[]' : '[]'}}';

void main() {
  final feed = [
    _release('v1.15.0-beta.2', prerelease: true),
    _release('v1.14.0'),
    _release('v1.13.1-r9', prerelease: true),
    _release('v1.16.0', draft: true),
  ].join(',');
  final feedJson = '[$feed]';

  test('official releases only by default', () {
    final release = parseReleaseList(feedJson);
    expect(release, isNotNull);
    expect(release!.version, '1.14.0');
  });

  test('the opt-in follows the newest pre-release', () {
    final release = parseReleaseList(feedJson, includePrereleases: true);
    expect(release!.version, '1.15.0-beta.2');
  });

  test('a draft never counts, with or without the opt-in', () {
    final draftsOnly =
        '[${_release('v1.16.0', draft: true)},'
        '${_release('v1.17.0-beta', prerelease: true, draft: true)}]';
    expect(parseReleaseList(draftsOnly), isNull);
    expect(parseReleaseList(draftsOnly, includePrereleases: true), isNull);
  });

  test('an official release keeps its place below a newer pre-release', () {
    final mixed =
        '[${_release('v1.20.0', prerelease: true)},'
        '${_release('v1.19.0')},'
        '${_release('v1.18.0')}]';
    expect(parseReleaseList(mixed)!.version, '1.19.0');
    expect(
      parseReleaseList(mixed, includePrereleases: true)!.version,
      '1.20.0',
    );
  });
}
