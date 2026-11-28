//
//  topic_navigation_layout_test.dart
//
//  A bot topic chat's topic screen paints its tabs through
//  TopicNavigationLayout, not through the transcript's TopicTabStrip. The
//  tabs-position control has to exist there too: top under the header, or
//  bottom between the topic content and the composer.
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/channels/topic_navigation.dart';
import 'package:mithka/channels/topic_tabs_placement.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required TopicTabsPlacement placement,
    VoidCallback? onTogglePlacement,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: TopicNavigationLayout(
          topics: const [
            TopicNavigationItem(id: 1, name: 'Releases', isPinned: true),
            TopicNavigationItem(id: 2, name: 'Questions'),
          ],
          selectedTopicId: 1,
          // Forces the horizontal bar even on a wide test surface.
          hasForumTabs: true,
          onSelected: (_) {},
          placement: placement,
          onTogglePlacement: onTogglePlacement,
          bottomBar: const SizedBox(
            key: ValueKey('topic-composer'),
            height: 56,
          ),
          child: const SizedBox.expand(key: ValueKey('topic-content')),
        ),
      ),
    ),
  );

  Future<void> pumpHost(
    WidgetTester tester, {
    required TopicTabsPlacement placement,
    VoidCallback? onTogglePlacement,
  }) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final theme = ThemeController(await SharedPreferences.getInstance());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: host(placement: placement, onTogglePlacement: onTogglePlacement),
      ),
    );
    await tester.pump();
  }

  testWidgets('tabs sit above the content and offer the side dock', (
    tester,
  ) async {
    var toggles = 0;
    await pumpHost(
      tester,
      placement: TopicTabsPlacement.top,
      onTogglePlacement: () => toggles++,
    );

    final tabs = tester.getRect(
      find.byKey(const ValueKey('topic-navigation-top')),
    );
    final content = tester.getRect(find.byKey(const ValueKey('topic-content')));
    final composer = tester.getRect(
      find.byKey(const ValueKey('topic-composer')),
    );
    expect(tabs.bottom, lessThanOrEqualTo(content.top));
    expect(composer.top, greaterThanOrEqualTo(content.bottom));
    // exteraless's first step from the top is the side dock.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppIcon && identical(widget.icon, HeroAppIcons.arrowLeft),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('topic-tabs-placement-toggle')));
    expect(toggles, 1);
  });

  testWidgets('a side placement docks the column beside the content', (
    tester,
  ) async {
    await pumpHost(
      tester,
      placement: TopicTabsPlacement.side,
      onTogglePlacement: () {},
    );

    final navigation = tester.getRect(
      find.byKey(const ValueKey('topic-navigation-left')),
    );
    final content = tester.getRect(find.byKey(const ValueKey('topic-content')));
    final composer = tester.getRect(
      find.byKey(const ValueKey('topic-composer')),
    );
    expect(navigation.left, 0);
    expect(content.left, greaterThanOrEqualTo(navigation.right));
    expect(composer.top, greaterThanOrEqualTo(content.bottom));
  });

  testWidgets('the moved bar sits between the content and the composer', (
    tester,
  ) async {
    await pumpHost(
      tester,
      placement: TopicTabsPlacement.bottom,
      onTogglePlacement: () {},
    );

    final tabs = tester.getRect(
      find.byKey(const ValueKey('topic-navigation-top')),
    );
    final content = tester.getRect(find.byKey(const ValueKey('topic-content')));
    final composer = tester.getRect(
      find.byKey(const ValueKey('topic-composer')),
    );
    expect(tabs.top, greaterThanOrEqualTo(content.bottom));
    expect(tabs.bottom, lessThanOrEqualTo(composer.top));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppIcon && identical(widget.icon, HeroAppIcons.arrowUp),
      ),
      findsOneWidget,
    );
  });

  testWidgets('without a placement control the bar stays a plain top bar', (
    tester,
  ) async {
    await pumpHost(tester, placement: TopicTabsPlacement.top);
    expect(
      find.byKey(const ValueKey('topic-tabs-placement-toggle')),
      findsNothing,
    );
  });
}
