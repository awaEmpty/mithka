//
//  media_prefetch.dart
//
//  Starts a message's media download *before* the user needs it:
//
//  * The transcript asks for the rows just outside the viewport, so a photo is
//    already on disk by the time it is scrolled into view. The reference
//    client's FileLoader does the same from MessageObject (loadFile is called
//    when a row is laid out ahead of the viewport, not when it is painted).
//  * The history mirror asks for the media of every recorded message, so a
//    chat the user never opens still gets its snapshot — exteraless behaves
//    this way because DownloadController queues the message's photo as soon
//    as the update arrives.
//
//  Both callers pass through the auto-download preset: a prefetch never
//  fetches more than the current network's limits allow, and never fetches
//  anything when the preset is off. Prefetches run at a lower TDLib priority
//  than anything on screen, so a real request always wins the bandwidth.
//

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../settings/downloads_storage/auto_download_media_controller.dart';
import '../../tdlib/json_helpers.dart';
import '../../tdlib/td_image_loader.dart';
import '../../tdlib/td_models.dart';

enum PrefetchMediaKind { photo, video, document }

/// One file a prefetch would like on disk, with the preset limit it must fit.
class PrefetchCandidate {
  const PrefetchCandidate({
    required this.file,
    required this.kind,
    this.chatId,
    this.messageId,
  });

  final TdFileRef file;
  final PrefetchMediaKind kind;
  final int? chatId;
  final int? messageId;

  int get fileId => file.id;
  int get size => file.size ?? 0;
}

/// Network the device is on, as far as the auto-download presets care.
enum PrefetchNetwork { wifi, mobile }

class MediaPrefetch {
  MediaPrefetch({
    Future<bool> Function(int fileId)? download,
    AutoDownloadProfile Function()? wifiProfile,
    AutoDownloadProfile Function()? mobileProfile,
    Future<PrefetchNetwork> Function()? networkProbe,
    bool Function(ChatKind? kind)? allowsKind,
  }) : _download = download ?? _defaultDownload,
       _allowsKind =
           allowsKind ??
           AutoDownloadMediaController.shared.allowsAutoDownloadForKind,
       _wifiProfile =
           wifiProfile ?? (() => AutoDownloadMediaController.shared.wifi),
       _mobileProfile =
           mobileProfile ?? (() => AutoDownloadMediaController.shared.mobile),
       _networkProbe = networkProbe ?? _probeNetwork;

  static final MediaPrefetch _instance = MediaPrefetch();

  /// Set by tests that record messages without a network: the mirror calls
  /// [shared], and a test wants to observe those calls instead of running
  /// them.
  @visibleForTesting
  static MediaPrefetch? debugInstance;

  static MediaPrefetch get shared => debugInstance ?? _instance;

  /// Below the loader's foreground priorities (30–32), so a visible file
  /// always pre-empts a prefetch.
  static const prefetchPriority = 12;

  final Future<bool> Function(int fileId) _download;
  final AutoDownloadProfile Function() _wifiProfile;
  final AutoDownloadProfile Function() _mobileProfile;
  final Future<PrefetchNetwork> Function() _networkProbe;

  /// The chat-type half of the gate: the reference client's preset mask.
  final bool Function(ChatKind? kind) _allowsKind;

  /// File ids already asked for in this process. A prefetch is best effort:
  /// asking twice would only spend a query, and TDLib keeps the request alive
  /// across viewport changes anyway.
  final Set<int> _requested = <int>{};

  /// A long session scrolls thousands of rows; the memo is only a guard
  /// against re-asking, so it may start over rather than grow forever.
  static const _requestedLimit = 4000;

  @visibleForTesting
  void resetForTesting() => _requested.clear();

  AutoDownloadProfile _currentProfile() {
    switch (_lastNetwork) {
      case PrefetchNetwork.wifi:
        return _wifiProfile();
      case PrefetchNetwork.mobile:
        return _mobileProfile();
      case null:
        return const AutoDownloadProfile.low();
    }
  }

  PrefetchNetwork? _lastNetwork;

  /// Refreshes the network classification the preset lookup uses. Called from
  /// [prefetch] on its first run and by the chat view when the connection
  /// changes.
  Future<void> refreshNetwork() async {
    try {
      _lastNetwork = await _networkProbe();
    } catch (_) {
      _lastNetwork ??= PrefetchNetwork.mobile;
    }
  }

  static Future<bool> _defaultDownload(int fileId) async {
    final response = await TdFileCenter.shared.downloadPriorityFile(
      fileId,
      priority: prefetchPriority,
    );
    return response != null;
  }

  /// The media a message would want on disk, in the order it becomes useful:
  /// the photo first (it is what the row paints), then a video, then a file.
  static List<PrefetchCandidate> candidatesOf(ChatMessage message) {
    final out = <PrefetchCandidate>[];
    void add(TdFileRef? file, PrefetchMediaKind kind) {
      if (file == null || file.id <= 0) return;
      out.add(
        PrefetchCandidate(
          file: file,
          kind: kind,
          chatId: message.chatId,
          messageId: message.id,
        ),
      );
    }

    add(message.image, PrefetchMediaKind.photo);
    add(message.video, PrefetchMediaKind.video);
    add(message.document?.file, PrefetchMediaKind.document);
    return out;
  }

  /// The media a raw TDLib content payload carries, in the order the history
  /// mirror would keep it: the largest photo size, then a video/animation
  /// file, then a document. Used by the mirror for chats the user has not
  /// opened, where no widget ever asks for the file.
  static List<PrefetchCandidate> candidatesOfTdContent(
    Map<String, dynamic>? content,
  ) {
    if (content == null) return const [];
    TdFileRef? refOf(Map<String, dynamic>? node) {
      if (node == null) return null;
      final id = jsonInt(node['id']) ?? 0;
      if (id <= 0) return null;
      final size = jsonInt(node['size']) ?? jsonInt(node['expected_size']);
      final local = node.obj('local');
      return TdFileRef(id: id, size: size, localPath: local?.str('path'));
    }

    final out = <PrefetchCandidate>[];
    void add(
      TdFileRef? file,
      PrefetchMediaKind kind, {
      int? chatId,
      int? messageId,
    }) {
      if (file == null) return;
      out.add(
        PrefetchCandidate(
          file: file,
          kind: kind,
          chatId: chatId,
          messageId: messageId,
        ),
      );
    }

    switch (content.type) {
      case 'messagePhoto':
        // TDLib lists photo sizes smallest first; the last one is the full
        // picture, which is the snapshot the mirror wants.
        final sizes = content.obj('photo')?.objects('sizes');
        if (sizes != null && sizes.isNotEmpty) {
          add(refOf(sizes.last.obj('photo')), PrefetchMediaKind.photo);
        }
      case 'messageVideo':
        add(refOf(content.obj('video')?.obj('video')), PrefetchMediaKind.video);
      case 'messageAnimation':
        add(
          refOf(content.obj('animation')?.obj('animation')),
          PrefetchMediaKind.document,
        );
      case 'messageDocument':
        add(
          refOf(content.obj('document')?.obj('document')),
          PrefetchMediaKind.document,
        );
    }
    return out;
  }

  /// Prefetches the media of one raw content payload (the history mirror's
  /// entry point, where the chat kind is not known yet).
  Future<int> prefetchTdContent(Map<String, dynamic>? content) =>
      prefetch(candidatesOfTdContent(content));

  /// Requests whatever in [candidates] the preset allows. Returns the number
  /// of files actually asked for.
  Future<int> prefetch(
    List<PrefetchCandidate> candidates, {
    ChatKind? chatKind,
  }) async {
    if (candidates.isEmpty) return 0;
    // The reference client gates every automatic fetch on the chat-type mask
    // as well as the network preset (`DownloadController.Preset.mask`).
    if (!_allowsKind(chatKind)) return 0;
    if (_lastNetwork == null) await refreshNetwork();
    final profile = _currentProfile();
    if (!profile.enabled) return 0;
    var started = 0;
    for (final candidate in candidates) {
      if (started >= 2) break; // a row needs its photo; two is plenty
      if (!_allows(profile, candidate)) continue;
      if (_requested.length >= _requestedLimit) _requested.clear();
      if (!_requested.add(candidate.fileId)) continue;
      final started_ = await _download(candidate.fileId);
      if (!started_) {
        _requested.remove(candidate.fileId);
        continue;
      }
      started += 1;
    }
    return started;
  }

  /// Prefetches one message's media (the transcript's off-screen window).
  Future<int> prefetchMessage(ChatMessage message, {ChatKind? chatKind}) {
    if (message.isService || message.id <= 0) return Future<int>.value(0);
    return prefetch(candidatesOf(message), chatKind: chatKind);
  }

  bool _allows(AutoDownloadProfile profile, PrefetchCandidate candidate) {
    final size = candidate.size;
    if (size <= 0) return false; // unknown size: let the visible row ask
    return switch (candidate.kind) {
      PrefetchMediaKind.photo => size <= profile.maxPhotoBytes,
      PrefetchMediaKind.video => size <= profile.maxVideoBytes,
      PrefetchMediaKind.document => size <= profile.maxOtherBytes,
    };
  }

  @visibleForTesting
  Future<PrefetchNetwork> probeNetworkForTesting() => _probeNetwork();

  static Future<PrefetchNetwork> _probeNetwork() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.startsWith('wlan') ||
            name.startsWith('wl') ||
            name.startsWith('en') ||
            name.startsWith('eth') ||
            name.startsWith('ap')) {
          return PrefetchNetwork.wifi;
        }
        // rmnet*/ccmni*/pdp*/wwan*/clat* are mobile; they fall through to the
        // metered answer below instead of ending the loop.
      }
      // The loopback-only case and an unknown transport are both treated as
      // metered: the mobile preset is the conservative one, and calling a
      // metered link "wifi" would spend the user's data.
      return PrefetchNetwork.mobile;
    } catch (_) {
      return PrefetchNetwork.mobile;
    }
  }
}
