//
//  instant_view_view.dart
//
//  The native Instant View reader: Telegram's own article page for
//  Telegraph, Twitter and every other site with an Instant View template.
//  It loads `webPageInstantView`, lays the page blocks out at a readable
//  measure and keeps Telegram's semantics — links route through the app,
//  anchors scroll within the article, related articles open another page,
//  search highlights inside the text, and the text size is adjustable.
//

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../components/app_icons.dart';
import '../../components/app_interactive_surface.dart';
import '../../components/toast.dart';
import '../../components/ui_components.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';
import '../links_search/link_preview_fixer.dart';
import 'instant_view_blocks.dart';
import 'instant_view_links.dart';
import 'instant_view_loader.dart';
import 'instant_view_models.dart';
import 'instant_view_text.dart';

/// Default and allowed article text sizes, matching exteraless's 12–30pt
/// Instant View size slider.
const double _minInstantViewFontSize = 12;
const double _maxInstantViewFontSize = 30;
const double _baseInstantViewFontSize = 16;
const String _fontSizePreferenceKey = 'instantViewFontSize.v1';

class InstantViewView extends StatefulWidget {
  const InstantViewView({
    super.key,
    required this.url,
    this.accountSlot,
    this.loader,
    this.initialPage,
    this.fallbackUrl,
  });

  final String url;
  final int? accountSlot;

  /// Shared loader; nested articles reuse the opener's cache.
  final InstantViewLoader? loader;
  final InstantViewPage? initialPage;

  /// Where "Open in browser" (and a failed automatic load) goes. Defaults to
  /// [url].
  final String? fallbackUrl;

  @override
  State<InstantViewView> createState() => _InstantViewViewState();
}

class _InstantViewViewState extends State<InstantViewView> {
  late final InstantViewLoader _loader =
      widget.loader ?? InstantViewLoader.td(accountSlot: widget.accountSlot);
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _anchorKeys = {};
  final List<GlobalKey> _blockKeys = [];
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  InstantViewPage? _page;
  Object? _error;
  var _loading = false;
  var _showBackToTop = false;
  var _fontSize = _baseInstantViewFontSize;
  var _searching = false;
  var _query = '';
  List<int> _matches = const [];
  var _matchIndex = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_restoreFontSize());
    final initial = widget.initialPage ?? _loader.cached(widget.url);
    if (initial != null && !initial.isEmpty) {
      _adopt(initial);
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _restoreFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_fontSizePreferenceKey);
    if (!mounted || saved == null) return;
    setState(
      () => _fontSize = saved.clamp(
        _minInstantViewFontSize,
        _maxInstantViewFontSize,
      ),
    );
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 900;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _adopt(InstantViewPage page) {
    _page = page;
    while (_blockKeys.length < page.blocks.length) {
      _blockKeys.add(GlobalKey());
    }
    if (_searching && _query.trim().isNotEmpty) _refreshMatches();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    InstantViewPage? page;
    Object? failure;
    try {
      page = await _loader.load(widget.url);
    } catch (error) {
      failure = error;
    }
    // An x.com link never has a template of its own; the Tweet mirror does.
    // Reading the mirror is still Telegram's own Instant View, not a local
    // extraction, so this is the one retry the reader performs.
    if (page == null && LinkPreviewFixer.isTwitterUrl(widget.url)) {
      final mirror = LinkPreviewFixer.forcedPreviewUrl(widget.url);
      if (mirror != null && mirror != widget.url) {
        try {
          page = await _loader.load(mirror);
        } catch (error) {
          failure = error;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page != null) {
        _adopt(page);
      } else {
        _error = failure ?? InstantViewUnavailable(widget.url);
      }
    });
  }

  void _scrollToAnchor(String anchor, String fallbackUrl) {
    final key = _anchorKeys[anchor];
    final target = key?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: AppMotion.responsive,
        curve: AppMotion.standard,
        alignment: 0.08,
      );
      return;
    }
    if (fallbackUrl.isNotEmpty) {
      openIvUrl(context, fallbackUrl);
    }
  }

  void _openArticle(String url) {
    Navigator.of(context).push<void>(
      AppPageRoute<void>(
        pageBuilder: (_, _, _) => InstantViewView(
          url: url,
          accountSlot: widget.accountSlot,
          loader: _loader,
        ),
      ),
    );
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    showToast(context, AppStringKeys.messageLinkCopied);
  }

  // MARK: - Search

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = '';
        _matches = const [];
        _matchIndex = 0;
        _searchController.clear();
        _searchFocus.unfocus();
      }
    });
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  void _updateQuery(String value) {
    setState(() {
      _query = value;
      _refreshMatches();
      _matchIndex = 0;
    });
    if (_matches.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToMatch(0));
    }
  }

  void _refreshMatches() {
    final page = _page;
    final query = _query.trim().toLowerCase();
    if (page == null || query.isEmpty) {
      _matches = const [];
      return;
    }
    _matches = [
      for (var i = 0; i < page.blocks.length; i++)
        if (ivBlockPlainText(page.blocks[i]).toLowerCase().contains(query)) i,
    ];
  }

  void _jumpToMatch(int delta) {
    if (_matches.isEmpty) return;
    final next = (_matchIndex + delta) % _matches.length;
    _matchIndex = next < 0 ? next + _matches.length : next;
    final target = _blockKeys[_matches[_matchIndex]].currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: AppMotion.responsive,
      curve: AppMotion.standard,
      alignment: 0.12,
    );
    setState(() {});
  }

  // MARK: - Text size

  Future<void> _showTextSize() async {
    var size = _fontSize;
    await showAppModalSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SettingsPanel(
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xxl,
              AppSpacing.lg,
              AppSpacing.xxl,
              AppSpacing.lg,
            ),
            child: StatefulBuilder(
              builder: (context, setSheetState) {
                final c = context.colors;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      AppStrings.t(AppStringKeys.instantViewTextSize),
                      style: AppTextStyle.callout(
                        c.textSecondary,
                      ).copyWith(fontWeight: AppTextWeight.semibold),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Slider(
                      key: const ValueKey('instantViewTextSizeSlider'),
                      min: _minInstantViewFontSize,
                      max: _maxInstantViewFontSize,
                      divisions:
                          (_maxInstantViewFontSize - _minInstantViewFontSize)
                              .round(),
                      value: size,
                      onChanged: (value) {
                        setSheetState(() => size = value);
                        _setFontSize(value);
                      },
                    ),
                    Text(
                      'Aa',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: size,
                        height: 1.3,
                        color: c.textPrimary,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _setFontSize(double value) {
    setState(() => _fontSize = value);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setDouble(_fontSizePreferenceKey, value),
      ),
    );
  }

  // MARK: - Page menu

  Future<void> _showPageMenu() async {
    await showAppModalSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SettingsPanel(
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsRow(
                key: const ValueKey('instantViewCopyLink'),
                title: AppStrings.t(AppStringKeys.profileDetailCopyLink),
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.link),
                showChevron: false,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_copyLink());
                },
              ),
              const SettingsDivider(),
              SettingsRow(
                key: const ValueKey('instantViewOpenInBrowser'),
                title: AppStrings.t(AppStringKeys.instantViewOpenInBrowser),
                leading: const SettingsLeadingIcon(
                  icon: HeroAppIcons.arrowTopRight,
                ),
                showChevron: false,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    openIvUrlInBrowser(
                      context,
                      widget.fallbackUrl ?? widget.url,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // MARK: - Build

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          NavHeader(
            title: _headerTitle,
            onBack: Navigator.of(context).maybePop,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderAction(
                  key: const ValueKey('instantViewSearchAction'),
                  semanticLabel: AppStrings.t(AppStringKeys.instantViewSearch),
                  icon: HeroAppIcons.magnifyingGlass,
                  active: _searching,
                  onTap: _toggleSearch,
                ),
                _HeaderAction(
                  key: const ValueKey('instantViewTextSizeAction'),
                  semanticLabel: AppStrings.t(
                    AppStringKeys.instantViewTextSize,
                  ),
                  icon: HeroAppIcons.font,
                  onTap: () => unawaited(_showTextSize()),
                ),
                _HeaderAction(
                  key: const ValueKey('instantViewMenuAction'),
                  semanticLabel: AppStrings.t(AppStringKeys.momentsMore),
                  icon: HeroAppIcons.ellipsis,
                  onTap: () => unawaited(_showPageMenu()),
                ),
              ],
            ),
          ),
          if (_searching) _searchBar(context),
          SizedBox(
            height: 2,
            child: _loading
                ? const LinearProgressIndicator(minHeight: 2)
                : const SizedBox.shrink(),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final c = context.colors;
    final count = _matches.isEmpty
        ? '0/0'
        : '${_matchIndex + 1}/${_matches.length}';
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: c.navBar,
        border: Border(
          bottom: BorderSide(color: c.divider, width: AppMetric.divider),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('instantViewSearchField'),
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _updateQuery,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _jumpToMatch(1),
              style: AppTextStyle.body(c.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: AppStrings.t(AppStringKeys.instantViewSearch),
                hintStyle: AppTextStyle.body(c.textTertiary),
              ),
            ),
          ),
          Text(count, style: AppTextStyle.caption(c.textSecondary)),
          _HeaderAction(
            semanticLabel: AppStrings.t(AppStringKeys.instantViewPreviousMatch),
            icon: HeroAppIcons.chevronUp,
            compact: true,
            onTap: () => _jumpToMatch(-1),
          ),
          _HeaderAction(
            semanticLabel: AppStrings.t(AppStringKeys.instantViewNextMatch),
            icon: HeroAppIcons.chevronDown,
            compact: true,
            onTap: () => _jumpToMatch(1),
          ),
          _HeaderAction(
            key: const ValueKey('instantViewSearchClose'),
            semanticLabel: AppStrings.t(AppStringKeys.musicPlayerClose),
            icon: HeroAppIcons.xmark,
            compact: true,
            onTap: _toggleSearch,
          ),
        ],
      ),
    );
  }

  String get _headerTitle {
    final page = _page;
    if (page != null) {
      for (final block in page.blocks) {
        if (block is IvTitleBlock) {
          final title = ivTextToPlain(block.title).trim();
          if (title.isNotEmpty) return title;
        }
      }
    }
    final uri = Uri.tryParse(widget.url);
    final host = uri?.host ?? '';
    if (host.isEmpty) return AppStrings.t(AppStringKeys.instantViewTitle);
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  Widget _body(BuildContext context) {
    if (_page == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_page == null) {
      return _InstantViewError(
        onRetry: () => unawaited(_load()),
        onOpenInBrowser: () =>
            openIvUrlInBrowser(context, widget.fallbackUrl ?? widget.url),
      );
    }
    final page = _page!;
    final systemScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(
                systemScale * _fontSize / _baseInstantViewFontSize,
              ),
            ),
            child: Directionality(
              textDirection: page.isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: SelectionArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth > 760;
                    final gutter = wide ? 32.0 : 20.0;
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: ListView.builder(
                          key: const ValueKey('instantViewArticle'),
                          controller: _scroll,
                          padding: EdgeInsets.only(
                            top: 10,
                            bottom: 48 + MediaQuery.paddingOf(context).bottom,
                          ),
                          itemCount: page.blocks.length,
                          itemBuilder: (context, index) {
                            return KeyedSubtree(
                              key: _blockKeys[index],
                              child: IvBlockView(
                                block: page.blocks[index],
                                ctx: IvRenderContext(
                                  context: context,
                                  typography: _typography(context),
                                  horizontalPadding: gutter,
                                  anchorKeyFor: _keyForAnchor,
                                  onAnchor: _scrollToAnchor,
                                  onOpenArticle: _openArticle,
                                  accountSlot: widget.accountSlot,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 24 + MediaQuery.paddingOf(context).bottom,
          child: AnimatedSwitcher(
            duration: AppMotion.quick,
            child: _showBackToTop
                ? _BackToTopButton(
                    key: const ValueKey('instantViewBackToTop'),
                    onTap: () => _scroll.animateTo(
                      0,
                      duration: AppMotion.responsive,
                      curve: AppMotion.standard,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  GlobalKey _keyForAnchor(String name) {
    return _anchorKeys.putIfAbsent(name, GlobalKey.new);
  }

  IvTypography _typography(BuildContext context) {
    final c = context.colors;
    return IvTypography(
      base: TextStyle(
        fontSize: _baseInstantViewFontSize,
        height: 1.5,
        color: c.textPrimary,
        decoration: TextDecoration.none,
      ),
      accent: c.linkBlue,
      secondary: c.textSecondary,
      codeBackground: c.searchFill,
      highlight: _query.trim(),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    super.key,
    required this.semanticLabel,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.compact = false,
  });

  final String semanticLabel;
  final AppIconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = compact ? 36.0 : 40.0;
    return AppInteractiveSurface(
      semanticLabel: semanticLabel,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: AppIcon(
            icon,
            size: compact ? AppIconSize.md : AppIconSize.lg,
            color: active ? AppTheme.brand : c.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _BackToTopButton extends StatelessWidget {
  const _BackToTopButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.navBar,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 42,
          child: Center(
            child: AppIcon(
              HeroAppIcons.arrowUp,
              size: 20,
              color: c.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _InstantViewError extends StatelessWidget {
  const _InstantViewError({
    required this.onRetry,
    required this.onOpenInBrowser,
  });

  final VoidCallback onRetry;
  final VoidCallback onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(HeroAppIcons.flash, size: 34, color: c.textTertiary),
            const SizedBox(height: 12),
            Text(
              AppStrings.t(AppStringKeys.instantViewLoadFailed),
              textAlign: TextAlign.center,
              style: AppTextStyle.body(c.textSecondary),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: onRetry,
                  child: Text(AppStrings.t(AppStringKeys.instantViewRetry)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onOpenInBrowser,
                  child: Text(
                    AppStrings.t(AppStringKeys.instantViewOpenInBrowser),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
