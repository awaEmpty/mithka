import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/android_share_intake.dart';
import 'package:mithka/platform/android_share_intent.dart';
import 'package:mithka/tdlib/td_models.dart' show ChatKind, ChatSummary;

AndroidShareIntentPayload _payload({
  String text = '',
  List<String> uris = const [],
}) {
  return AndroidShareIntentPayload(
    id: 'share-${text.hashCode}-${uris.join()}',
    text: text,
    mimeType: uris.isEmpty ? 'text/plain' : 'application/pdf',
    uris: uris,
  );
}

const _file = AndroidSharedFile(
  path: '/data/cache/mithka-share-1-report.pdf',
  fileName: 'report.pdf',
  mimeType: 'application/pdf',
);

ChatSummary _chat() => ChatSummary(
  id: 42,
  title: 'Saved Messages',
  lastMessage: '',
  lastMessageId: 0,
  date: 0,
  unreadCount: 0,
  order: 0,
  isMuted: false,
  kind: ChatKind.privateChat,
);

class _FakeSource implements AndroidShareSource {
  _FakeSource(this.payloads);

  final List<AndroidShareIntentPayload> payloads;
  final List<List<String>> copiedUris = <List<String>>[];
  final List<List<String>> deletedPaths = <List<String>>[];
  Completer<List<AndroidSharedFile>>? copyGate;
  AndroidShareCopyException? copyError;
  List<AndroidSharedFile> files = const <AndroidSharedFile>[];

  @override
  AndroidShareIntentPayload? takePending() =>
      payloads.isEmpty ? null : payloads.removeAt(0);

  @override
  Future<List<AndroidSharedFile>> copyFiles(Iterable<String> uris) {
    copiedUris.add(uris.toList(growable: false));
    final failure = copyError;
    if (failure != null) return Future<List<AndroidSharedFile>>.error(failure);
    final gate = copyGate;
    if (gate != null) return gate.future;
    return Future<List<AndroidSharedFile>>.value(files);
  }

  @override
  Future<void> deleteFiles(Iterable<String> paths) async {
    deletedPaths.add(paths.toList(growable: false));
  }
}

void main() {
  test('a resumed app re-polls the platform for the pending share', () {
    // A push delivery is dropped when Dart has no handler yet (warm attach,
    // splash). The host polls again on every resume, and the payload is
    // non-consuming, so that delivery is recovered instead of lost.
    final host = File('lib/app/main_tab_view.dart').readAsStringSync();
    expect(host, contains('with WidgetsBindingObserver'));
    expect(host, contains('WidgetsBinding.instance.addObserver(this)'));
    final lifecycle = host.substring(
      host.indexOf('void didChangeAppLifecycleState('),
      host.indexOf('void _handleAndroidShareIntentChanged('),
    );
    expect(lifecycle, contains('AppLifecycleState.resumed'));
    expect(lifecycle, contains('_startAndroidShareIntake'));
  });

  testWidgets('the picker opens while the file copy is still running', (
    tester,
  ) async {
    final source = _FakeSource([
      _payload(uris: const ['content://provider/report.pdf']),
    ]);
    source.copyGate = Completer<List<AndroidSharedFile>>();
    var picked = 0;
    var sent = 0;
    var failures = 0;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async {
        picked += 1;
        return _chat();
      },
      sendText: (_, _, _) async {},
      sendFiles: (_, _, _, _) async {
        sent += 1;
      },
      reportFailure: (_) => failures += 1,
    );

    final presenting = intake.presentPending(context);
    await tester.pump();
    // The destination list is up before the provider copy has answered: a slow
    // or stuck copy can no longer make the share look like it did nothing.
    expect(picked, 1);
    expect(sent, 0);

    source.copyGate!.complete(const [_file]);
    await presenting;
    expect(sent, 1);
    expect(failures, 0);
    // The private copy is removed once the send flow is over.
    expect(source.deletedPaths.single, [_file.path]);
  });

  testWidgets('a provider answer with no usable file reports the failure', (
    tester,
  ) async {
    final source = _FakeSource([
      _payload(uris: const ['content://provider/empty.bin']),
    ]);
    var failures = 0;
    var sent = 0;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async => _chat(),
      sendText: (_, _, _) async {},
      sendFiles: (_, _, _, _) async => sent += 1,
      reportFailure: (_) => failures += 1,
    );

    await intake.presentPending(context);

    // Used to return silently, which is exactly the "nothing happened" report.
    expect(failures, 1);
    expect(sent, 0);
  });

  testWidgets('a failed copy reports and does not wedge the next share', (
    tester,
  ) async {
    final source = _FakeSource([
      _payload(uris: const ['content://provider/one.pdf']),
    ]);
    source.copyError = const AndroidShareCopyException('denied');
    var picked = 0;
    var failures = 0;
    var sent = 0;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async {
        picked += 1;
        return _chat();
      },
      sendText: (_, _, _) async {},
      sendFiles: (_, _, _, _) async => sent += 1,
      reportFailure: (_) => failures += 1,
    );

    await intake.presentPending(context);
    expect(failures, 1);
    expect(picked, 1);

    // The intake must be usable again: a stuck "presenting" latch used to make
    // every later share in the same process do nothing.
    source.copyError = null;
    source.files = const [_file];
    source.payloads.add(_payload(uris: const ['content://provider/two.pdf']));
    await intake.presentPending(context);
    expect(picked, 2);
    expect(sent, 1);
  });

  testWidgets('a text-only share writes the draft and never copies files', (
    tester,
  ) async {
    final source = _FakeSource([_payload(text: 'https://example.com/post')]);
    String? sentText;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async => _chat(),
      sendText: (_, _, text) async => sentText = text,
      sendFiles: (_, _, _, _) async {},
      reportFailure: (_) => fail('a text share is not a failure'),
    );

    await intake.presentPending(context);

    expect(sentText, 'https://example.com/post');
    expect(source.copiedUris, isEmpty);
  });

  testWidgets('cancelling the picker still deletes the copied temp file', (
    tester,
  ) async {
    final source = _FakeSource([
      _payload(uris: const ['content://provider/report.pdf']),
    ]);
    source.copyGate = Completer<List<AndroidSharedFile>>();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async => null,
      sendText: (_, _, _) async {},
      sendFiles: (_, _, _, _) async {},
      reportFailure: (_) => fail('a cancelled picker is not a failure'),
    );

    final presenting = intake.presentPending(context);
    await tester.pump();
    source.copyGate!.complete(const [_file]);
    await presenting;

    expect(source.deletedPaths.single, [_file.path]);
  });

  testWidgets('shares queued while one is being presented are drained', (
    tester,
  ) async {
    final source = _FakeSource([
      _payload(uris: const ['content://provider/one.pdf']),
      _payload(uris: const ['content://provider/two.pdf']),
    ]);
    source.files = const [_file];
    var sent = 0;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final intake = AndroidShareIntake(
      source: source,
      pickChat: (_) async => _chat(),
      sendText: (_, _, _) async {},
      sendFiles: (_, _, _, _) async => sent += 1,
      reportFailure: (_) => fail('both shares are readable'),
    );

    await intake.presentPending(context);

    expect(sent, 2);
    expect(source.copiedUris.length, 2);
  });
}
