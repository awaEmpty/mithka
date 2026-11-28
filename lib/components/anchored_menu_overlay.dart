//
//  anchored_menu_overlay.dart
//
//  The dim-and-scale entrance every anchored chat-list popup shares: the "+"
//  menu, the folder-filter menu and the edit-mode overflow column. Keeping it
//  in one widget is what makes those three read as one popup family — the
//  placement maths and the labels above it stay with their own call sites.
//

import 'package:flutter/material.dart';
import '../theme/app_motion.dart';

/// Keeps anchored menus mounted through their reverse animation so the
/// barrier, hit testing, and menu surface leave as one coherent motion.
///
/// The child must be the menu surface itself; the caller positions it. This
/// widget only paints the scrim and the scale/translate entrance.
class AnchoredMenuOverlay extends StatefulWidget {
  const AnchoredMenuOverlay({
    super.key,
    required this.visible,
    required this.top,
    required this.onDismiss,
    required this.child,
  });

  final bool visible;

  /// Distance from the viewport's top edge to the menu's own top edge.
  final double top;

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<AnchoredMenuOverlay> createState() => _AnchoredMenuOverlayState();
}

class _AnchoredMenuOverlayState extends State<AnchoredMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.responsive,
    reverseDuration: AppMotion.quick,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDuration();
    if (AppMotion.isReduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant AnchoredMenuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDuration();
    if (oldWidget.visible == widget.visible) return;
    if (AppMotion.isReduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _syncDuration() {
    _controller.duration = AppMotion.duration(context, AppMotion.responsive);
    _controller.reverseDuration = AppMotion.duration(context, AppMotion.quick);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          if (_controller.isDismissed) return const SizedBox.shrink();
          final progress = AppMotion.emphasized.transform(_controller.value);
          return IgnorePointer(
            ignoring: _controller.value == 0,
            child: ExcludeSemantics(
              excluding: _controller.value == 0,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismiss,
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: 0.12 * _controller.value,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: widget.top, right: 10),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: Opacity(
                          opacity: progress,
                          child: Transform.translate(
                            offset: Offset(0, -8 * (1 - progress)),
                            child: Transform.scale(
                              alignment: Alignment.topRight,
                              scale: 0.94 + 0.06 * progress,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
