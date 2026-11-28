//
//  instant_view_links.dart
//
//  Link/user taps inside an Instant View article. Articles carry plain
//  web URLs (and Telegram usernames); both route through the app's normal
//  link handler so t.me links open in Mithka and everything else follows
//  the user's browser preference.
//

import 'package:flutter/material.dart';

import '../../profile/profile_detail_view.dart';
import '../links_search/link_handler.dart';

/// Opens [url] from inside an article.
Future<void> openIvUrl(BuildContext context, String url) async {
  final target = url.trim();
  if (target.isEmpty) return;
  await openLink(context, target);
}

/// Opens [url] with the user's browser preference, never as an Instant
/// View. This is the reader's "Open in browser" action.
Future<void> openIvUrlInBrowser(BuildContext context, String url) async {
  final target = url.trim();
  if (target.isEmpty) return;
  await openLinkInBrowser(context, target);
}

/// Opens the profile behind a `richTextMentionName` run.
Future<void> openIvUser(BuildContext context, int? userId) async {
  if (userId == null || userId == 0) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ProfileDetailView(userId: userId)),
  );
}
