//
//  bot_topic_tab_strip_test.dart
//
//  The topic tab strip must borrow the chat list's folder-tab language:
//  an "All" tab first, per-topic tabs with the folder-style unread badge
//  pill, and the 4pt selection indicator under the chosen tab only. Its
//  scroll offset must survive a topic switch, because opening a topic
//  rebuilds the whole transcript beneath it.
//

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/channels/topic_navigation.dart';
import 'package:mithka/channels/topic_tabs_placement.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/components/chat_folder_icons.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _botChatAllTabKey = ValueKey('topic-tab-all');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget stripHost({
    required List<TopicNavigationItem> topics,
    required int chatId,
    int? selectedTopicId,
    bool showUnreadBadges = true,
    bool isLoading = false,
    ValueChanged<int?>? onSelected,
    void Function(TopicNavigationItem topic, Rect anchor)? onLongPress,
    TopicTabsPlacement placement = TopicTabsPlacement.top,
    VoidCallback? onTogglePlacement,
    bool reordering = false,
    ValueChanged<List<int>>? onReorder,
    VoidCallback? onReorderDone,
  }) => MaterialApp(
    theme: ThemeData(extensions: [AppColors.light]),
    locale: const Locale('en'),
    localizationsDelegates: const [AppLocalizations.delegate],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TopicTabStrip(
        chatId: chatId,
        topics: topics,
        selectedTopicId: selectedTopicId,
        showUnreadBadges: showUnreadBadges,
        isLoading: isLoading,
        onSelected: onSelected ?? (_) {},
        onLongPress: onLongPress,
        placement: placement,
        onTogglePlacement: onTogglePlacement,
        reordering: reordering,
        onReorder: onReorder,
        onReorderDone: onReorderDone,
      ),
    ),
  );

  Widget sideBarHost({
    required List<TopicNavigationItem> topics,
    required int chatId,
    int? selectedTopicId,
    bool showUnreadBadges = true,
    bool isLoading = false,
    ValueChanged<int?>? onSelected,
    void Function(TopicNavigationItem topic, Rect anchor)? onLongPress,
    TopicTabsPlacement placement = TopicTabsPlacement.side,
    VoidCallback? onTogglePlacement,
  }) => MaterialApp(
    theme: ThemeData(extensions: [AppColors.light]),
    locale: const Locale('en'),
    localizationsDelegates: const [AppLocalizations.delegate],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TopicTabsSideBar(
              chatId: chatId,
              topics: topics,
              selectedTopicId: selectedTopicId,
              showUnreadBadges: showUnreadBadges,
              isLoading: isLoading,
              onSelected: onSelected ?? (_) {},
              onLongPress: onLongPress,
              onTogglePlacement: onTogglePlacement,
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );

  final topics = [
    const TopicNavigationItem(id: 10, name: 'Support', unreadCount: 3),
    const TopicNavigationItem(
      id: 20,
      name: 'FAQ',
      unreadCount: 150,
      isMuted: true,
    ),
  ];

  final manyTopics = [
    for (var i = 1; i <= 8; i++)
      TopicNavigationItem(id: i * 10, name: 'Topic $i'),
  ];

  testWidgets('renders All tab first, then topic tabs with badges', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      stripHost(chatId: 1, topics: topics, selectedTopicId: 10),
    );

    expect(find.byKey(_botChatAllTabKey), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('FAQ'), findsOneWidget);
    // Folder-style badge pills after each topic label.
    expect(find.byType(FolderUnreadBadge), findsNWidgets(2));
    expect(find.byKey(const ValueKey('topic-tab-unread-10')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('topic-tab-unread-10')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    // The overflow cap matches the folder badge default (99+).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('topic-tab-unread-20')),
        matching: find.text('99+'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('honours the folder badge visibility setting', (tester) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      stripHost(chatId: 2, topics: topics, showUnreadBadges: false),
    );
    expect(find.byType(FolderUnreadBadge), findsNothing);
  });

  testWidgets('long press reports the topic tab and its rect, never All', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final pressed = <int>[];
    Rect? anchor;
    await tester.pumpWidget(
      stripHost(
        chatId: 3,
        topics: topics,
        onLongPress: (topic, rect) {
          pressed.add(topic.id);
          anchor = rect;
        },
      ),
    );

    final tab = find.byKey(const ValueKey('topic-tab-10'));
    final tabRect = tester.getRect(tab);
    await tester.longPress(tab);
    expect(pressed, [10]);
    // The host hangs its menu off the tab itself, so the reported anchor is
    // the tab's own box, not the strip or the touch point.
    expect(anchor!.left, closeTo(tabRect.left, 0.01));
    expect(anchor!.top, closeTo(tabRect.top, 0.01));
    expect(anchor!.width, closeTo(tabRect.width, 0.01));
    expect(anchor!.height, closeTo(tabRect.height, 0.01));

    // The All pseudo-topic has nothing to manage.
    await tester.longPress(find.byKey(_botChatAllTabKey));
    expect(pressed, [10]);
  });

  // `isLoading` only fires while the topic page is empty, so the placeholder
  // is the last slot and the strip is ["All", placeholder]. Reading topics[0]
  // there used to throw, and Flutter swaps a failed list item for an error
  // box — release builds paint that as an opaque grey block over the right
  // side of the bar, in both light and dark themes.
  testWidgets('loading with an empty topic page shows no error box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      stripHost(chatId: 9, topics: const [], isLoading: true),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    // The "All" tab stays put while the page is in flight.
    expect(find.byKey(_botChatAllTabKey), findsOneWidget);
    // The bar spans the full width so the header colour covers all of it.
    expect(tester.getSize(find.byType(TopicTabStrip)).width, 390);
  });

  testWidgets('selection follows the open transcript and taps switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final selections = <int?>[];
    await tester.pumpWidget(
      stripHost(
        chatId: 3,
        topics: topics,
        selectedTopicId: 20,
        onSelected: selections.add,
      ),
    );

    // The selected tab's 4pt indicator paints solid brand; the unselected
    // tabs keep the fully transparent variant, so exactly one is lit.
    final lit = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == AppTheme.brand &&
          (widget.constraints is BoxConstraints) &&
          (widget.constraints as BoxConstraints).maxHeight == 4,
    );
    expect(lit, findsOneWidget);

    await tester.tap(find.text('Support'));
    await tester.pump();
    expect(selections, equals([10]));

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(selections, equals([10, null]));
  });

  // Opening a topic replaces the whole ChatView (its state reads the topic
  // once), so the strip is a brand-new widget/state each time. The offset
  // memory is the only thing carrying the user's scroll position across.
  testWidgets('scroll offset survives a topic switch (transcript rebuild)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TopicTabStripScrollMemory.resetForTesting();

    int? selected = 10;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => stripHost(
          chatId: 7,
          topics: manyTopics,
          selectedTopicId: selected,
          onSelected: (id) => setState(() => selected = id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll the strip so several topics sit off-screen to the right.
    await tester.drag(find.byType(TopicTabStrip), const Offset(-260, 0));
    await tester.pumpAndSettle();
    final offsetBefore = TopicTabStripScrollMemory.read(7);
    expect(offsetBefore, isNotNull);
    expect(offsetBefore! > 0, isTrue, reason: 'strip must be scrolled');

    // The transcript swap: fresh strip state, different selected topic.
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => stripHost(
          chatId: 7,
          topics: manyTopics,
          selectedTopicId: 80,
          onSelected: (id) => setState(() => selected = id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      TopicTabStripScrollMemory.read(7),
      closeTo(offsetBefore, 0.5),
      reason: 'switching topics must not move the tab strip',
    );
    // And the live scroll position reflects the memory, not a reset to 0.
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(TopicTabStrip),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, closeTo(offsetBefore, 0.5));
  });

  testWidgets('the placement toggle walks top, side, bottom and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var toggles = 0;
    await tester.pumpWidget(
      stripHost(chatId: 11, topics: topics, onTogglePlacement: () => toggles++),
    );

    // Tabs on top offer exteraless's first step: dock at the side.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppIcon && identical(widget.icon, HeroAppIcons.arrowLeft),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('topic-tabs-placement-toggle')));
    expect(toggles, 1);

    // The side bar's own control offers the way down to the composer.
    await tester.pumpWidget(
      sideBarHost(
        chatId: 11,
        topics: topics,
        onTogglePlacement: () => toggles++,
      ),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppIcon && identical(widget.icon, HeroAppIcons.arrowDown),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('topic-tabs-placement-toggle')));
    expect(toggles, 2);

    // Tabs above the composer offer the way back up.
    await tester.pumpWidget(
      stripHost(
        chatId: 11,
        topics: topics,
        placement: TopicTabsPlacement.bottom,
        onTogglePlacement: () => toggles++,
      ),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppIcon && identical(widget.icon, HeroAppIcons.arrowUp),
      ),
      findsOneWidget,
    );
  });

  testWidgets('reorder mode drags only pinned tabs and closes on Done', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final pinnedTopics = [
      const TopicNavigationItem(id: 10, name: 'Pinned A', isPinned: true),
      const TopicNavigationItem(id: 20, name: 'Pinned B', isPinned: true),
      const TopicNavigationItem(id: 30, name: 'Recent'),
    ];
    var done = 0;
    List<int>? reordered;
    await tester.pumpWidget(
      stripHost(
        chatId: 12,
        topics: pinnedTopics,
        reordering: true,
        onReorder: (ids) => reordered = ids,
        onReorderDone: () => done++,
      ),
    );

    expect(find.byKey(const ValueKey('topic-tabs-reorder')), findsOneWidget);
    // Unpinned topics stay out of the draggable block, and the All tab is not
    // part of the pin order.
    expect(find.text('Pinned A'), findsOneWidget);
    expect(find.text('Pinned B'), findsOneWidget);
    expect(find.text('Recent'), findsNothing);
    expect(find.byKey(const ValueKey('topic-tab-all')), findsNothing);
    expect(
      find.byKey(const ValueKey('topic-tabs-placement-toggle')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('topic-tabs-reorder-done')));
    expect(done, 1);
    expect(reordered, isNull);
  });

  test('a drag move rewrites only the pinned order', () {
    expect(reorderPinnedTopicIds([10, 20, 30], 0, 2), [20, 30, 10]);
    expect(reorderPinnedTopicIds([10, 20, 30], 2, 0), [30, 10, 20]);
    // Out-of-range requests leave the order alone.
    expect(reorderPinnedTopicIds([10, 20], 5, 0), [10, 20]);
  });

  // exteraless's side tabs (`TopicsTabsView`'s `VerticalTabView`s): a 64dp
  // column docked at the conversation's left edge, the glyph above up to
  // three lines of the name, the unread pill on the glyph and the brand bar
  // on the selected row's left edge.
  testWidgets('the side bar docks 64dp wide with icon-over-name tabs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      sideBarHost(chatId: 21, topics: topics, selectedTopicId: 10),
    );

    expect(tester.getSize(find.byType(TopicTabsSideBar)).width, 64);
    expect(find.byKey(const ValueKey('topic-tabs-side-bar')), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('FAQ'), findsOneWidget);
    expect(find.byType(FolderUnreadBadge), findsNWidgets(2));

    // The selected row carries the brand bar on its left edge; the other rows
    // stay plain.
    final brandBars = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == AppTheme.brand &&
          widget.constraints is BoxConstraints &&
          (widget.constraints as BoxConstraints).maxWidth == 3,
    );
    expect(brandBars, findsOneWidget);
  });

  testWidgets('side bar taps and long presses resolve their topic', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final selections = <int?>[];
    final pressed = <int>[];
    await tester.pumpWidget(
      sideBarHost(
        chatId: 22,
        topics: topics,
        onSelected: selections.add,
        onLongPress: (topic, _) => pressed.add(topic.id),
      ),
    );

    await tester.tap(find.text('Support'));
    await tester.pump();
    expect(selections, [10]);

    await tester.longPress(find.byKey(const ValueKey('topic-tab-10')));
    expect(pressed, [10]);

    // The All pseudo-topic has nothing to manage.
    await tester.longPress(find.byKey(_botChatAllTabKey));
    expect(pressed, [10]);
  });

  testWidgets('the side bar keeps an empty topic page quiet', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      sideBarHost(chatId: 23, topics: const [], isLoading: true),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byKey(_botChatAllTabKey), findsOneWidget);
  });

  testWidgets('side reorder drags the pinned topics and closes on Done', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final pinnedTopics = [
      const TopicNavigationItem(id: 10, name: 'Pinned A', isPinned: true),
      const TopicNavigationItem(id: 20, name: 'Pinned B', isPinned: true),
      const TopicNavigationItem(id: 30, name: 'Recent'),
    ];
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: Row(
              children: [
                TopicTabsSideBar(
                  chatId: 24,
                  topics: pinnedTopics,
                  selectedTopicId: 10,
                  onSelected: (_) {},
                  reordering: true,
                  onReorder: (_) {},
                  onReorderDone: () => done++,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('topic-tabs-side-reorder')),
      findsOneWidget,
    );
    expect(find.text('Pinned A'), findsOneWidget);
    expect(find.text('Pinned B'), findsOneWidget);
    expect(find.text('Recent'), findsNothing);
    expect(
      find.byKey(const ValueKey('topic-tabs-placement-toggle')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('topic-tabs-reorder-done')));
    expect(done, 1);
  });

  test('the placement store round-trips the side home', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TopicTabsPlacementStore.shared;
    store.resetForTesting();
    await store.save(0, 42, TopicTabsPlacement.side);
    expect(store.placementFor(0, 42), TopicTabsPlacement.side);
    expect(await store.load(0, 42), TopicTabsPlacement.side);
    await store.save(0, 42, TopicTabsPlacement.bottom);
    expect(await store.load(0, 42), TopicTabsPlacement.bottom);
    // exteraless's cycle order is top → side → bottom → top.
    expect(
      nextTopicTabsPlacement(TopicTabsPlacement.top),
      TopicTabsPlacement.side,
    );
    expect(
      nextTopicTabsPlacement(TopicTabsPlacement.side),
      TopicTabsPlacement.bottom,
    );
    expect(
      nextTopicTabsPlacement(TopicTabsPlacement.bottom),
      TopicTabsPlacement.top,
    );
  });
}
