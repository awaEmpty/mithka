import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../chat/composer/outgoing_attachment.dart';

/// The data Android provides for an ACTION_SEND or ACTION_SEND_MULTIPLE
/// launch. Provider URIs stay native; Dart receives private cache paths only
/// after [copyFiles] has completed.
@immutable
class AndroidShareIntentPayload {
  const AndroidShareIntentPayload({
    required this.id,
    required this.text,
    required this.mimeType,
    required this.uris,
  });

  factory AndroidShareIntentPayload.fromMap(Map<dynamic, dynamic> value) {
    final uris = [
      for (final item
          in value['uris'] is List ? value['uris'] as List : const [])
        if (item is String && item.trim().isNotEmpty) item,
    ];
    final text = value['text'] is String ? value['text'] as String : '';
    final mimeType = value['mimeType'] is String
        ? (value['mimeType'] as String).trim()
        : '';
    final fallbackId = '$mimeType\n$text\n${uris.join('\n')}';
    return AndroidShareIntentPayload(
      id: value['id'] is String && (value['id'] as String).isNotEmpty
          ? value['id'] as String
          : fallbackId,
      text: text,
      mimeType: mimeType,
      uris: List.unmodifiable(uris),
    );
  }

  final String id;
  final String text;
  final String mimeType;
  final List<String> uris;

  bool get hasContent => text.trim().isNotEmpty || uris.isNotEmpty;
}

@immutable
class AndroidSharedFile {
  const AndroidSharedFile({
    required this.path,
    required this.fileName,
    required this.mimeType,
  });

  factory AndroidSharedFile.fromMap(Map<dynamic, dynamic> value) {
    return AndroidSharedFile(
      path: value['path'] is String ? value['path'] as String : '',
      fileName: value['fileName'] is String ? value['fileName'] as String : '',
      mimeType: value['mimeType'] is String
          ? (value['mimeType'] as String).trim()
          : 'application/octet-stream',
    );
  }

  final String path;
  final String fileName;
  final String mimeType;

  bool get isUsable => path.isNotEmpty;

  OutgoingAttachmentKind get attachmentKind {
    final mime = mimeType.toLowerCase();
    if (mime == 'image/gif') return OutgoingAttachmentKind.animation;
    if (mime.startsWith('image/')) return OutgoingAttachmentKind.photo;
    if (mime.startsWith('video/')) return OutgoingAttachmentKind.video;
    if (mime.startsWith('audio/')) return OutgoingAttachmentKind.audio;
    return OutgoingAttachmentKind.document;
  }
}

/// What the share intake needs from the platform bridge, so the orchestration
/// can be exercised without an Android channel.
abstract interface class AndroidShareSource {
  AndroidShareIntentPayload? takePending();

  Future<List<AndroidSharedFile>> copyFiles(Iterable<String> uris);

  Future<void> deleteFiles(Iterable<String> paths);
}

/// A share whose files could not be copied out of the provider.
///
/// Callers must surface this: a share that lands on a chat picker and then
/// silently drops its files is indistinguishable from a share that did nothing.
class AndroidShareCopyException implements Exception {
  const AndroidShareCopyException(this.cause);

  final Object cause;

  @override
  String toString() => 'AndroidShareCopyException($cause)';
}

/// Android's share target bridge. It deliberately owns only intent parsing and
/// temporary-file lifecycle; the UI remains the same chat picker and media
/// preview used for content shared from inside Mithka.
class AndroidShareIntentController extends ChangeNotifier
    implements AndroidShareSource {
  AndroidShareIntentController._();

  static final shared = AndroidShareIntentController._();

  static const _channel = MethodChannel('mithka/share_intent');
  bool _started = false;
  AndroidShareIntentPayload? _pending;
  final List<AndroidShareIntentPayload> _queued = <AndroidShareIntentPayload>[];
  final Set<String> _seenIds = <String>{};

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get hasPending => _pending != null;

  /// Registers the native handler and asks for the share that opened this
  /// window. Safe to call again: the platform keeps the payload until the
  /// process ends, and [AndroidShareIntentPayload.id] de-duplicates it.
  Future<void> start() async {
    if (!supported) return;
    if (!_started) {
      _started = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    }
    await _pollInitial();
  }

  /// Re-asks the platform for the share that opened this window.
  ///
  /// A warm attach hands the intent to an engine whose Dart side may not have
  /// registered [start] yet; that delivery is dropped by the platform channel.
  /// Polling again recovers it instead of losing the share.
  Future<void> refresh() async {
    if (!supported) return;
    await _pollInitial();
  }

  Future<void> _pollInitial() async {
    try {
      final initial = await _channel.invokeMethod<dynamic>('initial');
      if (initial is Map) _enqueue(AndroidShareIntentPayload.fromMap(initial));
    } on MissingPluginException {
      // No native shell (tests, desktop): nothing to recover.
    } on PlatformException {
      // A share target can be started while Flutter is still attaching its
      // engine. The native side keeps the payload for the next initial call.
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'share' || call.arguments is! Map) return;
    _enqueue(AndroidShareIntentPayload.fromMap(call.arguments as Map));
  }

  void _enqueue(AndroidShareIntentPayload payload) {
    if (!payload.hasContent || !_seenIds.add(payload.id)) return;
    if (_seenIds.length > 32) _seenIds.remove(_seenIds.first);
    if (_pending == null) {
      _pending = payload;
    } else {
      _queued.add(payload);
    }
    notifyListeners();
  }

  @override
  AndroidShareIntentPayload? takePending() {
    final payload = _pending;
    if (payload == null) return null;
    _pending = _queued.isEmpty ? null : _queued.removeAt(0);
    notifyListeners();
    return payload;
  }

  @override
  Future<List<AndroidSharedFile>> copyFiles(Iterable<String> uris) async {
    if (!supported) return const [];
    final List<dynamic> raw;
    try {
      final result = await _channel.invokeMethod<dynamic>(
        'copyFiles',
        uris.toList(growable: false),
      );
      raw = result is List ? result : const [];
    } on PlatformException catch (error) {
      throw AndroidShareCopyException(error);
    } on MissingPluginException catch (error) {
      throw AndroidShareCopyException(error);
    }
    return [
      for (final value in raw)
        if (value is Map)
          AndroidSharedFile.fromMap(value)
        else
          const AndroidSharedFile(
            path: '',
            fileName: '',
            mimeType: 'application/octet-stream',
          ),
    ].where((file) => file.isUsable).toList(growable: false);
  }

  @override
  Future<void> deleteFiles(Iterable<String> paths) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('deleteFiles', paths.toList());
    } on PlatformException {
      // Cache cleanup is best effort; native code rejects paths outside its
      // own cache directory even if a caller supplies one accidentally.
    }
  }
}
