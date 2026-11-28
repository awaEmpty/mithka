//
//  folder_reorder_presentation_test.dart
//
//  The folder reorder sheet lives over the whole tab shell. On the tab's own
//  navigator it would sit UNDER the liquid-glass bottom bar (the footer is
//  painted outside that navigator), so the sheet must be pushed on the root
//  navigator.
//

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/bottom_bar_layout.dart';
import 'package:mithka/chats/chat_folder_tab_menu.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/chat_folder_service.dart';

class _RecordingObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  testWidgets('the reorder sheet opens on the root navigator', (tester) async {
    final rootObserver = _RecordingObserver();
    final tabObserver = _RecordingObserver();
    final service = ChatFolderService(
      query: (request) async => <String, dynamic>{'@type': 'ok'},
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [rootObserver],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: BottomBarLayout(
          overlay: true,
          body: Navigator(
            observers: [tabObserver],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (tabContext) => Scaffold(
                body: Center(
                  child: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showChatFolderReorderSheet(
                        context: context,
                        folders: const [],
                        mainListPosition: 0,
                        service: service,
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
          footer: const SizedBox(
            key: ValueKey('glass-bottom-bar'),
            height: 96,
            child: ColoredBox(color: Color(0xFF102030)),
          ),
        ),
      ),
    );
    final rootBefore = rootObserver.pushes;
    final tabBefore = tabObserver.pushes;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatFolderReorderSheet), findsOneWidget);
    expect(rootObserver.pushes, rootBefore + 1);
    expect(tabObserver.pushes, tabBefore);
  });
}
