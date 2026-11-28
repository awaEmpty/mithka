//
//  app_anchored_menu.dart
//
//  The app's tab-anchored action menu: a narrow popup that hangs off the
//  pressed control (folder tab, topic tab, in-chat activity pill) instead of
//  a wide bottom sheet. One implementation keeps every anchored menu on the
//  same chrome, placement math and entrance animation.
//

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mithka/components/app_icons.dart';
import 'package:mithka/components/app_interactive_surface.dart';
import 'package:mithka/theme/app_motion.dart';
import 'package:mithka/theme/app_theme.dart';
import '../app/bottom_bar_layout.dart';

/// One command in an anchored popup menu.
///
/// A row either runs [onSelected] or, when it carries [children], opens a
/// submenu in the same card — exteraless's ActionBarMenuSubItem with its own
/// popup page, the shape its Mute row takes: the durations belong to the
/// command, not to a separate sheet.
class AppMenuAction {
  const AppMenuAction({
    required this.key,
    required this.label,
    this.icon,
    this.onSelected,
    this.children,
    this.destructive = false,
    this.sectionStart = false,
  }) : assert(
         onSelected != null || children != null,
         'a menu row needs a command or a submenu',
       );

  /// Stable suffix for the row's key, e.g. `edit` or `mark-read`.
  final String key;

  /// Already localized label.
  final String label;

  /// Leading glyph. Submenu rows leave it null: exteraless's submenu items are
  /// text-only, and the label still starts on the parent's text line.
  final AppIconData? icon;
  final VoidCallback? onSelected;

  /// Rows of the submenu this row opens instead of running a command.
  final List<AppMenuAction>? children;

  /// Destructive commands render in the danger color, like exteraless's red
  /// Delete item in a tab's popup.
  final bool destructive;

  /// Draws a separator above this row, grouping the column the way
  /// exteraless's `addColoredGap` splits its chat menu into blocks.
  final bool sectionStart;
}

/// A group separator's height inside an anchored column: a hairline plus
/// breathing room on both sides.
const double appAnchoredMenuSectionGap = 9;

/// Menu chrome metrics shared with the placement math and tests: 36px rows on
/// a compact 196px column with an 8px vertical inset, mirroring exteraless's
/// ActionBarPopupWindow column.
const double appAnchoredMenuRowHeight = 36;
const double appAnchoredMenuVerticalInset = 8;
const double appAnchoredMenuMinWidth = 196;

/// The optional title block above the rows: 8px top inset, a 13px semibold
/// line, 6px below.
const double appAnchoredMenuTitleHeight = 30;

/// A submenu's back row: one full-height row plus the hairline under it.
const double appAnchoredMenuBackRowDivider = 1;

/// How an anchored menu is drawn.
///
/// The app owns exactly two sizes of this popup, and they must stay
/// tellable apart: the compact column hangs off a tab or an in-chat pill,
/// while the chat header's overflow menu is exteraless's action-bar submenu —
/// taller rows, the 16sp menu label, a column that hugs its widest label, and
/// an edge that lines up with the `⋮` that opened it.
enum AppAnchoredMenuStyle {
  compact(
    rowHeight: appAnchoredMenuRowHeight,
    verticalInset: appAnchoredMenuVerticalInset,
    minWidth: appAnchoredMenuMinWidth,
    maxWidth: appAnchoredMenuMinWidth,
    iconSize: 19,
    iconSlot: 31,
    labelSize: 15,
    labelWeight: FontWeight.w500,
    horizontalPadding: 16,
    rowRadius: AppRadius.md,
    surfaceRadius: AppRadius.control,
    hugLabels: false,
    rightAligned: false,
  ),

  /// The chat header's `⋮` menu: exteraless `ActionBarMenuSubItem` geometry —
  /// 48dp rows, 18dp row insets, a 22px glyph in its 43dp slot, and a 16sp
  /// label.
  header(
    rowHeight: 48,
    verticalInset: 8,
    minWidth: appAnchoredMenuMinWidth,
    maxWidth: 300,
    iconSize: 22,
    iconSlot: 43,
    labelSize: 16,
    labelWeight: FontWeight.w400,
    horizontalPadding: 18,
    rowRadius: AppRadius.control,
    surfaceRadius: AppRadius.card,
    hugLabels: true,
    rightAligned: true,
  );

  const AppAnchoredMenuStyle({
    required this.rowHeight,
    required this.verticalInset,
    required this.minWidth,
    required this.maxWidth,
    required this.iconSize,
    required this.iconSlot,
    required this.labelSize,
    required this.labelWeight,
    required this.horizontalPadding,
    required this.rowRadius,
    required this.surfaceRadius,
    required this.hugLabels,
    required this.rightAligned,
  });

  final double rowHeight;
  final double verticalInset;
  final double minWidth;
  final double maxWidth;
  final double iconSize;

  /// Width of the leading glyph slot, so every label in a menu starts on one
  /// vertical line instead of following its own icon's width.
  final double iconSlot;
  final double labelSize;
  final FontWeight labelWeight;
  final double horizontalPadding;
  final double rowRadius;
  final double surfaceRadius;

  /// Sizes the column to its widest label (inside [minWidth]–[maxWidth])
  /// instead of pinning it to [minWidth].
  final bool hugLabels;

  /// Lines the column's right edge up with the pressed control's right edge —
  /// the way a header overflow hangs under its own button.
  final bool rightAligned;
}

/// The dim layer's opacity, exteraless's tab ItemOptions value
/// (`setDimAlpha(0x60)` on DialogsActivity's filter tabs).
const double appAnchoredMenuDimOpacity = 0x60 / 0xff;

/// The menu's entrance mirrors exteraless's PopupContextAnimation: fade in
/// 150ms while scaling 95%→100% over 200ms with a light overshoot from the
/// corner nearest the pressed control. Exit reverses both at the same tempo.
const Duration _menuScaleDuration = Duration(milliseconds: 200);

/// Where the 150ms fade and dim tracks end inside the 200ms entrance.
const double _menuFastTrack = 150 / 200;

const Curve _menuGrowCurve = Cubic(0.34, 1.56, 0.64, 1.0); // easeOutBack

/// Keeps the popup off the window edges on every side.
const double _menuViewportMargin = 8;

@visibleForTesting
double appAnchoredMenuHeightFor(
  int actionCount, {
  bool hasTitle = false,
  int sectionCount = 0,
  AppAnchoredMenuStyle style = AppAnchoredMenuStyle.compact,
}) =>
    style.verticalInset * 2 +
    (hasTitle ? appAnchoredMenuTitleHeight : 0) +
    math.max(0, sectionCount) * appAnchoredMenuSectionGap +
    math.max(0, actionCount) * style.rowHeight;

/// The column's width for [labels]: the compact family is a fixed
/// [AppAnchoredMenuStyle.minWidth]; a label-hugging style measures the widest
/// row the way exteraless sizes its action-bar submenu, clamped between its
/// minimum and maximum.
@visibleForTesting
double appAnchoredMenuWidthFor(
  BuildContext context,
  AppAnchoredMenuStyle style,
  Iterable<String> labels,
) {
  if (!style.hugLabels) return style.minWidth;
  final painter = TextPainter(
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  );
  var widest = 0.0;
  for (final label in labels) {
    painter.text = TextSpan(
      text: label,
      style: TextStyle(fontSize: style.labelSize),
    );
    painter.layout();
    widest = math.max(widest, painter.width);
  }
  painter.dispose();
  final fitted =
      style.horizontalPadding * 2 + style.iconSlot + widest + 2; // 2px slack
  return fitted.clamp(style.minWidth, style.maxWidth).toDouble();
}

/// Where a menu of [menuSize] opens for a control at [anchor], staying inside
/// the viewport: below the control when it fits, above when it does not,
/// horizontally clamped with the menu's left edge near the control like
/// exteraless's ItemOptions with Gravity.LEFT. [alignRight] hangs the column's
/// right edge under the control's instead (a header overflow button).
@visibleForTesting
Offset appAnchoredMenuOriginFor({
  required Rect anchor,
  required Size viewport,
  required Size menuSize,
  double margin = 8,
  double? gap,
  bool alignRight = false,
  double bottomInset = 0,
}) {
  // [margin] keeps the menu off the viewport edges; [gap] is the distance to
  // the pressed control itself, so a caller can hug a tab strip without also
  // pinning the menu to the screen edge. [bottomInset] is chrome drawn OVER
  // the body (the liquid-glass tab bar): the usable viewport ends above it,
  // so a menu that would reach under it flips up instead.
  final controlGap = gap ?? margin;
  final usableBottom = math.max(margin, viewport.height - bottomInset - margin);
  final maxLeft = math.max(margin, viewport.width - menuSize.width - margin);
  final wantedLeft = alignRight ? anchor.right - menuSize.width : anchor.left;
  final left = wantedLeft.clamp(margin, maxLeft).toDouble();
  final belowTop = anchor.bottom + controlGap;
  final aboveTop = anchor.top - controlGap - menuSize.height;
  final double top;
  if (belowTop + menuSize.height <= usableBottom) {
    top = belowTop;
  } else if (aboveTop >= margin) {
    top = aboveTop;
  } else {
    // Neither side fits (menu taller than the usable viewport): pin its
    // bottom above the overlay chrome and let the column clip/scroll.
    top = math.max(margin, usableBottom - menuSize.height);
  }
  return Offset(left, top);
}

/// Shows [actions] anchored to [anchor] — the pressed tab or pill.
///
/// A long press on a folder tab, a topic tab or an in-chat activity pill all
/// open this same command list. The menu hangs off the pressed control like
/// exteraless's ItemOptions popup instead of a bottom sheet, so it reads as
/// acting on that control.
Future<void> showAppAnchoredMenu({
  required BuildContext context,
  required Rect anchor,
  required List<AppMenuAction> actions,
  String? header,
  double gap = 8,
  AppAnchoredMenuStyle style = AppAnchoredMenuStyle.compact,
}) {
  if (actions.isEmpty) return Future<void>.value();
  final overlay = Overlay.of(context, rootOverlay: true);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (overlayBox == null || !overlayBox.hasSize) {
    return Future<void>.value();
  }
  final anchorInOverlay = Rect.fromPoints(
    overlayBox.globalToLocal(anchor.topLeft),
    overlayBox.globalToLocal(anchor.bottomRight),
  );
  final completer = Completer<void>();
  var removed = false;
  void removeEntry(OverlayEntry? entry) {
    if (removed) return;
    removed = true;
    entry?.remove();
  }

  // Chrome painted over the body (the liquid-glass tab bar) claims the
  // bottom of the screen: a tab menu must open above it instead of under it.
  final bottomInset =
      context.getInheritedWidgetOfExactType<BottomBarInset>()?.bottom ?? 0;
  late final AppAnchoredMenuPopup menu;
  menu = AppAnchoredMenuPopup(
    anchor: anchorInOverlay,
    gap: gap,
    header: header,
    actions: actions,
    style: style,
    bottomInset: bottomInset,
    onDismissed: () {
      removeEntry(menu.entry);
      completer.complete();
    },
  );
  final entry = OverlayEntry(builder: (_) => menu);
  menu.entry = entry;
  overlay.insert(entry);
  return completer.future;
}

/// An app-owned anchored popup: a barrier that eats taps and Escape, one
/// compact menu card, and rows that pop the menu before invoking their
/// command.
// The mutable `entry` link is assigned by the factory right after
// construction, so this widget deliberately forgoes @immutable.
// ignore: must_be_immutable
class AppAnchoredMenuPopup extends StatefulWidget {
  AppAnchoredMenuPopup({
    super.key,
    required this.anchor,
    required this.actions,
    required this.onDismissed,
    this.header,
    this.gap = 8,
    this.style = AppAnchoredMenuStyle.compact,
    this.bottomInset = 0,
  });

  /// The pressed control's rect in the enclosing overlay's coordinates.
  final Rect anchor;

  /// Distance from the control to the menu's near edge. A tab strip passes a
  /// tighter gap so its menu hugs the bar instead of floating below it.
  final double gap;

  /// Optional caption naming the surface the menu acts on.
  final String? header;
  final List<AppMenuAction> actions;
  final AppAnchoredMenuStyle style;

  /// Height of chrome drawn over the body's bottom edge (the glass tab bar),
  /// so placement keeps the whole card above it.
  final double bottomInset;
  final VoidCallback onDismissed;

  /// The overlay entry this menu renders inside; assigned by
  /// [showAppAnchoredMenu] so a dismissal can remove it exactly once.
  OverlayEntry? entry;

  @override
  State<AppAnchoredMenuPopup> createState() => _AppAnchoredMenuPopupState();
}

class _AppAnchoredMenuPopupState extends State<AppAnchoredMenuPopup>
    with TickerProviderStateMixin {
  final FocusNode _menuFocus = FocusNode(debugLabel: 'Anchored popup menu');

  bool _open = true;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _menuScaleDuration,
  );

  /// The scrim's fade, the menu's fade, and the menu's grow share one
  /// controller so all three run in lockstep on the way in and out.
  late final Animation<double> _dim = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, _menuFastTrack, curve: AppMotion.standard),
  );
  late final Animation<double> _menuFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, _menuFastTrack),
  );
  late final Animation<double> _menuScale = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 1, curve: _menuGrowCurve),
  );

  bool _reducedSeen = false;

  /// The pages pushed so far. The first page is the caller's column; a row
  /// with children pushes another one onto the same card, so a submenu reads
  /// as belonging to the row that opened it instead of a second popup.
  late final List<_AppAnchoredMenuPage> _pages = [
    _AppAnchoredMenuPage(title: null, actions: widget.actions),
  ];

  bool get _hasHeader => (widget.header ?? '').isNotEmpty;
  bool get _inSubmenu => _pages.length > 1;
  _AppAnchoredMenuPage get _page => _pages.last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuFocus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reducedSeen) return;
    _reducedSeen = true;
    if (AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    // Torn down with the menu still open (its host route disappeared):
    // report the dismissal so the caller's future completes.
    if (_open) widget.onDismissed();
    _menuFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// A row with children swaps the card to its submenu; a leaf row runs its
  /// command and closes the menu.
  void _select(AppMenuAction action) {
    final children = action.children;
    if (children != null && children.isNotEmpty) {
      setState(
        () => _pages.add(
          _AppAnchoredMenuPage(title: action.label, actions: children),
        ),
      );
      return;
    }
    final invoke = action.onSelected;
    dismiss();
    invoke?.call();
  }

  /// Back out of a submenu — Escape or the header row — without closing the
  /// menu the user is still browsing.
  void _back() {
    if (!mounted || !_inSubmenu) return;
    setState(() => _pages.removeLast());
  }

  void dismiss() {
    if (!mounted || !_open) return;
    _open = false;
    if (!AppMotion.isReduced(context) &&
        _controller.status.isForwardOrCompleted) {
      unawaited(_controller.reverse().whenComplete(widget.onDismissed));
    } else {
      widget.onDismissed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = widget.style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        // The width measures every level, so opening a submenu resizes
        // nothing — the card stays where the finger left it.
        final menuWidth = appAnchoredMenuWidthFor(context, style, [
          for (final root in widget.actions) ...[
            root.label,
            for (final child in root.children ?? const <AppMenuAction>[])
              child.label,
          ],
        ]);
        final actions = _page.actions;
        final sectionCount = actions
            .where((action) => action.sectionStart)
            .length;
        final backRow = _inSubmenu
            ? style.rowHeight + appAnchoredMenuBackRowDivider
            : 0.0;
        final contentHeight =
            appAnchoredMenuHeightFor(
              actions.length,
              hasTitle: _hasHeader && !_inSubmenu,
              sectionCount: sectionCount,
              style: style,
            ) +
            backRow;
        // A chat menu can outgrow the screen (a channel admin's column carries
        // a dozen rows); exteraless caps the popup and scrolls its contents
        // instead of letting the column run off the window.
        final maxHeight = math.max(
          style.rowHeight,
          viewport.height - widget.bottomInset - 2 * _menuViewportMargin,
        );
        final menuSize = Size(menuWidth, math.min(contentHeight, maxHeight));
        final origin = appAnchoredMenuOriginFor(
          anchor: widget.anchor,
          viewport: viewport,
          menuSize: menuSize,
          gap: widget.gap,
          alignRight: style.rightAligned,
          bottomInset: widget.bottomInset,
        );
        // The menu grows from the corner nearest the pressed control,
        // matching exteraless's pivotX/pivotY on the control-adjacent corner:
        // below the control grows from its top-left corner, a flip above
        // grows from the bottom edge nearest the control's horizontal side.
        final growsFromBottom = origin.dy > widget.anchor.bottom;
        final growsFromRight = origin.dx > widget.anchor.left;
        final scaleAlignment = Alignment(
          growsFromRight ? -1 : 1,
          growsFromBottom ? -1 : 1,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('app-anchored-menu-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: dismiss,
              onSecondaryTap: dismiss,
              child: FadeTransition(
                opacity: _dim,
                child: ColoredBox(
                  key: const ValueKey('app-anchored-menu-scrim'),
                  color: Colors.black.withValues(
                    alpha: appAnchoredMenuDimOpacity,
                  ),
                ),
              ),
            ),
            Positioned(
              left: origin.dx,
              top: origin.dy,
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  // Escape backs out of a submenu first, the way exteraless's
                  // action bar pops one level per press.
                  const SingleActivator(LogicalKeyboardKey.escape): _inSubmenu
                      ? _back
                      : dismiss,
                },
                child: FocusTraversalGroup(
                  child: Focus(
                    focusNode: _menuFocus,
                    child: FadeTransition(
                      opacity: _menuFade,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.95,
                          end: 1,
                        ).animate(_menuScale),
                        alignment: scaleAlignment,
                        child: Container(
                          key: const ValueKey('app-anchored-menu'),
                          width: menuSize.width,
                          constraints: BoxConstraints(
                            maxHeight: menuSize.height,
                          ),
                          padding: EdgeInsets.symmetric(
                            vertical: style.verticalInset,
                          ),
                          decoration: BoxDecoration(
                            color: c.card,
                            borderRadius: BorderRadius.circular(
                              style.surfaceRadius,
                            ),
                            border: Border.all(color: c.divider, width: 0.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: style.rightAligned ? 0.24 : 0.2,
                                ),
                                blurRadius: style.rightAligned ? 22 : 18,
                                offset: Offset(0, style.rightAligned ? 8 : 6),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SingleChildScrollView(
                            key: const ValueKey('app-anchored-menu-scroll'),
                            padding: EdgeInsets.zero,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_inSubmenu) ...[
                                  _AppAnchoredMenuBackRow(
                                    title: _page.title ?? '',
                                    style: style,
                                    onTap: _back,
                                  ),
                                  Container(
                                    height: appAnchoredMenuBackRowDivider,
                                    color: c.divider,
                                  ),
                                ],
                                if (_hasHeader && !_inSubmenu)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      6,
                                    ),
                                    child: Text(
                                      widget.header!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: c.textSecondary,
                                      ),
                                    ),
                                  ),
                                for (final action in actions)
                                  _AppAnchoredMenuRow(
                                    action: action,
                                    style: style,
                                    onTap: () => _select(action),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One level of the card: the caller's column, or a submenu pushed over it.
class _AppAnchoredMenuPage {
  const _AppAnchoredMenuPage({required this.title, required this.actions});

  /// The parent row's label, shown beside the back chevron. Null on the root.
  final String? title;
  final List<AppMenuAction> actions;
}

/// The submenu's header: a back chevron and the parent row's label, the way
/// exteraless titles a pushed action-bar page.
class _AppAnchoredMenuBackRow extends StatelessWidget {
  const _AppAnchoredMenuBackRow({
    required this.title,
    required this.style,
    required this.onTap,
  });

  final String title;
  final AppAnchoredMenuStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppInteractiveSurface(
      key: const ValueKey('app-anchored-menu-back'),
      semanticLabel: title,
      onTap: onTap,
      borderRadius: BorderRadius.circular(style.rowRadius),
      child: SizedBox(
        height: style.rowHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: style.horizontalPadding),
          child: Row(
            children: [
              SizedBox(
                width: style.iconSlot,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppIcon(
                    HeroAppIcons.chevronLeft,
                    size: style.iconSize,
                    color: c.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: style.labelSize,
                    fontWeight: style.labelWeight,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppAnchoredMenuRow extends StatelessWidget {
  const _AppAnchoredMenuRow({
    required this.action,
    required this.style,
    required this.onTap,
  });

  final AppMenuAction action;
  final AppAnchoredMenuStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final destructiveColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFF6961)
        : AppTheme.tagRed;
    final foreground = action.destructive ? destructiveColor : c.textPrimary;
    final row = AppInteractiveSurface(
      key: ValueKey('app-anchored-menu-${action.key}'),
      semanticLabel: action.label,
      onTap: onTap,
      borderRadius: BorderRadius.circular(style.rowRadius),
      child: SizedBox(
        height: style.rowHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: style.horizontalPadding),
          child: Row(
            children: [
              SizedBox(
                width: style.iconSlot,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  // A submenu row keeps the slot empty so its label still
                  // starts on the line the parent's text does.
                  child: action.icon == null
                      ? null
                      : AppIcon(
                          action.icon!,
                          size: style.iconSize,
                          color: foreground,
                        ),
                ),
              ),
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: style.labelSize,
                    fontWeight: style.labelWeight,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!action.sectionStart) return row;
    // exteraless splits its chat menu with addColoredGap: one hairline per
    // block boundary, inset off the card's edge.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: style.horizontalPadding,
            vertical: 4,
          ),
          child: Container(height: 1, color: c.divider),
        ),
        row,
      ],
    );
  }
}
