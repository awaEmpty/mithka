import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mithka/platform/app_haptics.dart';
import 'package:provider/provider.dart';
import '../auth/account_store.dart';
import '../components/app_icons.dart';
import '../components/brand_mark.dart';
import '../components/photo_avatar.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../platform/keyboard_modifiers.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'local_app_lock_controller.dart';

@immutable
class _AppLockPalette {
  const _AppLockPalette({
    required this.backdropTop,
    required this.backdrop,
    required this.backdropBottom,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.vignette,
    required this.foreground,
    required this.secondary,
    required this.accent,
    required this.accentSoft,
    required this.error,
    required this.keyFillTop,
    required this.keyFillBottom,
    required this.keySheen,
    required this.keyRim,
    required this.keyShadow,
    required this.emblemFill,
    required this.emblemRim,
    required this.badgeFill,
    required this.footer,
  });

  factory _AppLockPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF0A0D14) : const Color(0xFFF4F7FC);
    final accent = isDark
        ? Color.lerp(scheme.primary, Colors.white, 0.28)!
        : scheme.primary;
    final accentSoft = Color.lerp(
      accent,
      isDark ? Colors.white : scheme.tertiary,
      0.45,
    )!;
    final foreground = isDark ? const Color(0xFFF4F7FC) : colors.textPrimary;
    final secondary = isDark
        ? const Color(0xB3F4F7FC)
        : colors.textSecondary.withValues(alpha: 0.92);
    return _AppLockPalette(
      backdropTop: isDark ? const Color(0xFF11161F) : const Color(0xFFFBFDFF),
      backdrop: base,
      backdropBottom: isDark
          ? const Color(0xFF070A10)
          : const Color(0xFFE7EDF7),
      glowPrimary: Color.alphaBlend(
        accent.withValues(alpha: isDark ? 0.30 : 0.16),
        base,
      ),
      glowSecondary: Color.alphaBlend(
        (scheme.tertiary).withValues(alpha: isDark ? 0.24 : 0.13),
        base,
      ),
      vignette: Colors.black.withValues(alpha: isDark ? 0.34 : 0.03),
      foreground: foreground,
      secondary: secondary,
      accent: accent,
      accentSoft: accentSoft,
      error: isDark
          ? Color.lerp(scheme.error, Colors.white, 0.18)!
          : scheme.error,
      keyFillTop: isDark
          ? Colors.white.withValues(alpha: 0.105)
          : Colors.white.withValues(alpha: 0.92),
      keyFillBottom: isDark
          ? Colors.white.withValues(alpha: 0.035)
          : Colors.white.withValues(alpha: 0.55),
      keySheen: Colors.white.withValues(alpha: isDark ? 0.10 : 0.85),
      keyRim: isDark
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.95),
      keyShadow: Colors.black.withValues(alpha: isDark ? 0.32 : 0.08),
      // The medallion is glass over the gate's own backdrop, so its rim reads
      // as light caught on an edge rather than a white sticker: tint the hairline
      // with the theme accent and keep the fill a wash of the same colour.
      emblemFill: isDark
          ? Color.alphaBlend(
              accent.withValues(alpha: 0.10),
              Colors.white.withValues(alpha: 0.05),
            )
          : Color.alphaBlend(
              accent.withValues(alpha: 0.06),
              Colors.white.withValues(alpha: 0.72),
            ),
      emblemRim: isDark
          ? Color.lerp(accent, Colors.white, 0.42)!.withValues(alpha: 0.62)
          : Color.lerp(accent, Colors.white, 0.58)!,
      badgeFill: isDark
          ? Color.alphaBlend(accent.withValues(alpha: 0.18), base)
          : accent,
      footer: secondary.withValues(alpha: 0.72),
    );
  }

  final Color backdropTop;
  final Color backdrop;
  final Color backdropBottom;
  final Color glowPrimary;
  final Color glowSecondary;
  final Color vignette;
  final Color foreground;
  final Color secondary;
  final Color accent;
  final Color accentSoft;
  final Color error;
  final Color keyFillTop;
  final Color keyFillBottom;
  final Color keySheen;
  final Color keyRim;
  final Color keyShadow;
  final Color emblemFill;
  final Color emblemRim;
  final Color badgeFill;
  final Color footer;
}

class LocalAppLockGate extends StatefulWidget {
  const LocalAppLockGate({super.key});

  @override
  State<LocalAppLockGate> createState() => _LocalAppLockGateState();
}

class _LocalAppLockGateState extends State<LocalAppLockGate>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int? _automaticBiometricEpoch;
  int? _pendingAutomaticBiometricEpoch;

  /// Drives the unlock hand-off: 1 shows the gate, 0 has fully handed the
  /// screen back to the app. Locking jumps straight back to 1 so a resume
  /// after the timeout can never paint the chat list for a frame first.
  late final AnimationController _visibility;
  LocalAppLockController? _lock;
  bool _overlayVisible = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    // Eager: dispose() must never be the first reader, or the ticker lookup
    // would run against a deactivated element.
    _visibility = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      value: 1,
    )..addStatusListener(_handleVisibilityStatus);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lock = context.read<LocalAppLockController>();
    if (!identical(lock, _lock)) {
      _lock?.removeListener(_handleLockChanged);
      _lock = lock..addListener(_handleLockChanged);
    }
  }

  void _handleLockChanged() {
    final locked = _lock?.locked ?? false;
    if (locked) {
      // No entrance fade: the gate must cover the app on the very first
      // frame after a re-lock. The emblem still springs in by itself.
      if (!_overlayVisible) setState(() => _overlayVisible = true);
      if (_visibility.value != 1) _visibility.value = 1;
    } else if (_overlayVisible &&
        _visibility.status != AnimationStatus.reverse) {
      _visibility.reverse();
    }
  }

  void _handleVisibilityStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _overlayVisible && mounted) {
      setState(() => _overlayVisible = false);
    }
  }

  @override
  void dispose() {
    _lock?.removeListener(_handleLockChanged);
    _visibility.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  Future<void> _authenticateAutomatically(
    LocalAppLockController controller,
    int epoch,
  ) async {
    try {
      if (!mounted ||
          !controller.locked ||
          controller.lockEpoch != epoch ||
          !_foreground) {
        return;
      }
      _automaticBiometricEpoch = epoch;
      await controller.authenticateBiometric(
        localizedReason: AppStringKeys.appLockBiometricReason.l10n(context),
      );
    } finally {
      if (mounted && _pendingAutomaticBiometricEpoch == epoch) {
        setState(() => _pendingAutomaticBiometricEpoch = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LocalAppLockController>();
    final locked = controller.locked;
    if (locked && !_overlayVisible) {
      // First frame of a launch that starts locked: show the gate at once,
      // never a frame of the app underneath.
      _overlayVisible = true;
    }
    if (!locked && !_overlayVisible) return const SizedBox.shrink();
    final epoch = controller.lockEpoch;
    final tryBiometricFirst =
        locked &&
        controller.biometricEnabled &&
        controller.biometricAvailable &&
        _automaticBiometricEpoch != epoch;
    if (tryBiometricFirst &&
        _pendingAutomaticBiometricEpoch != epoch &&
        !controller.authenticatingBiometrics &&
        _foreground) {
      _pendingAutomaticBiometricEpoch = epoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_authenticateAutomatically(controller, epoch));
      });
    }
    final Widget gate = controller.storageUnavailable
        ? _AppLockStorageUnavailableView(controller: controller)
        : _AppUnlockView(
            key: ValueKey(epoch),
            controller: controller,
            unlocked: !locked,
            biometricPending:
                locked &&
                (tryBiometricFirst ||
                    _pendingAutomaticBiometricEpoch == epoch ||
                    controller.authenticatingBiometrics),
          );
    return IgnorePointer(
      ignoring: !locked,
      child: ExcludeSemantics(
        excluding: !locked,
        child: AnimatedBuilder(
          animation: _visibility,
          child: gate,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(
              _visibility.value.clamp(0.0, 1.0),
            );
            return Opacity(
              key: const ValueKey('app-lock-gate-opacity'),
              opacity: t,
              // A hair of growth reads as the lock plate handing the screen
              // forward, and never exposes an edge the way a slide would.
              child: Transform.scale(scale: 1 + (1 - t) * 0.035, child: child),
            );
          },
        ),
      ),
    );
  }
}

class _AppLockStorageUnavailableView extends StatelessWidget {
  const _AppLockStorageUnavailableView({required this.controller});

  final LocalAppLockController controller;

  @override
  Widget build(BuildContext context) {
    final palette = _AppLockPalette.of(context);
    return _AppLockBackdrop(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStringKeys.appLockSetupFailed.l10n(context),
                    textAlign: TextAlign.center,
                    style: AppTextStyle.title(palette.foreground),
                  ),
                  const SizedBox(height: 18),
                  SettingsHeaderAction(
                    label: AppStringKeys.aiSummaryRetry,
                    enabled: !controller.readingStorage,
                    working: controller.readingStorage,
                    onTap: () => unawaited(controller.reloadFromStorage()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppUnlockView extends StatelessWidget {
  const _AppUnlockView({
    super.key,
    required this.controller,
    required this.biometricPending,
    this.unlocked = false,
  });

  final LocalAppLockController controller;
  final bool biometricPending;

  /// True while the gate is fading out after a successful unlock. The view
  /// stays mounted for the transition, so it must not look like a fresh
  /// challenge during those frames.
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    final type = controller.credentialType;
    if (type == null) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _AppLockBackdrop(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: SafeArea(
          child: _CredentialChallenge(
            type: type,
            title: AppStringKeys.appLockUnlockTitle,
            prompt: type == AppLockCredentialType.pin
                ? AppStringKeys.appLockEnterPin
                : AppStringKeys.appLockDrawGesture,
            leading: const _ActiveAccountLockAvatar(),
            lockScreenStyle: true,
            unlocked: unlocked,
            biometricPending: biometricPending,
            biometricKind: controller.biometricKind,
            showBiometric:
                controller.biometricEnabled && controller.biometricAvailable,
            onSubmit: (credential) async {
              final accepted = await controller.unlockWithCredential(
                credential,
              );
              return accepted
                  ? const _ChallengeResult.complete()
                  : _ChallengeResult.rejected(
                      type == AppLockCredentialType.pin
                          ? AppStringKeys.appLockWrongPin
                          : AppStringKeys.appLockWrongGesture,
                    );
            },
            onBiometric: () async {
              final result = await controller.authenticateBiometric(
                localizedReason: AppStringKeys.appLockBiometricReason.l10n(
                  context,
                ),
              );
              return _biometricError(result);
            },
          ),
        ),
      ),
    );
  }
}

class _AppLockBackdrop extends StatelessWidget {
  const _AppLockBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = _AppLockPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: palette.backdrop),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(painter: _AppLockBackdropPainter(palette)),
          ),
          child,
        ],
      ),
    );
  }
}

/// The aurora plate behind the lock screen: one vertical wash, two soft brand
/// glows and a vignette. Painted rather than stacked as blurred boxes so it
/// costs one layer on the lock screen's first frame.
class _AppLockBackdropPainter extends CustomPainter {
  const _AppLockBackdropPainter(this.palette);

  final _AppLockPalette palette;

  void _blob(Canvas canvas, Offset center, double radius, Color color) {
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(bounds),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.backdropTop,
            palette.backdrop,
            palette.backdropBottom,
          ],
          stops: const [0, 0.52, 1],
        ).createShader(rect),
    );
    _blob(
      canvas,
      Offset(size.width * 0.08, size.height * 0.02),
      size.width * 0.78,
      palette.glowPrimary,
    );
    _blob(
      canvas,
      Offset(size.width * 0.98, size.height * 0.34),
      size.width * 0.62,
      palette.glowSecondary,
    );
    _blob(
      canvas,
      Offset(size.width * 0.35, size.height * 1.02),
      size.width * 0.85,
      palette.glowPrimary.withValues(alpha: 0.55),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.22),
          radius: 1.15,
          colors: [Colors.transparent, palette.vignette],
          stops: const [0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _AppLockBackdropPainter oldDelegate) =>
      oldDelegate.palette.backdrop != palette.backdrop ||
      oldDelegate.palette.backdropTop != palette.backdropTop ||
      oldDelegate.palette.glowPrimary != palette.glowPrimary ||
      oldDelegate.palette.glowSecondary != palette.glowSecondary ||
      oldDelegate.palette.foreground != palette.foreground;
}

class _ActiveAccountLockAvatar extends StatefulWidget {
  const _ActiveAccountLockAvatar();

  @override
  State<_ActiveAccountLockAvatar> createState() =>
      _ActiveAccountLockAvatarState();
}

class _ActiveAccountLockAvatarState extends State<_ActiveAccountLockAvatar> {
  StreamSubscription<Map<String, dynamic>>? _updates;
  String _name = 'M';
  int? _userId;
  TdFileRef? _photo;

  @override
  void initState() {
    super.initState();
    _updates = TdClient.shared.subscribe().listen(_handleUpdate);
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    super.dispose();
  }

  void _handleUpdate(Map<String, dynamic> update) {
    if (update.type == 'updateAuthorizationState' &&
        update.obj('authorization_state')?.type == 'authorizationStateReady') {
      unawaited(_load());
      return;
    }
    if (update.type != 'updateUser') return;
    final user = update.obj('user');
    if (user != null && user.int64('id') == _userId) _apply(user);
  }

  Future<void> _load() async {
    try {
      final user = await TdClient.shared.query({'@type': 'getMe'});
      if (mounted) _apply(user);
    } catch (_) {
      // The authorization state may not be ready during the launch frame. Its
      // update retries this query while the monogram remains visible.
    }
  }

  void _apply(Map<String, dynamic> user) {
    final name = TDParse.userName(user);
    setState(() {
      _userId = user.int64('id');
      if (name.isNotEmpty) _name = name;
      _photo = TDParse.smallPhoto(user.obj('profile_photo'));
    });
  }

  @override
  Widget build(BuildContext context) {
    const size = 88.0;
    final palette = _AppLockPalette.of(context);
    String? avatarPath;
    try {
      avatarPath = context.watch<AccountStore>().activeSummary?.avatarPath;
    } on ProviderNotFoundException catch (_) {
      // Standalone previews can render the TDLib-backed avatar directly.
    }
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.foreground,
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: avatarPath != null && avatarPath.isNotEmpty
            ? Image.file(
                File(avatarPath),
                fit: BoxFit.cover,
                cacheWidth: cacheSize,
                cacheHeight: cacheSize,
                errorBuilder: (_, _, _) =>
                    PhotoAvatar(title: _name, photo: _photo, size: size - 4),
              )
            : PhotoAvatar(title: _name, photo: _photo, size: size - 4),
      ),
    );
  }
}

class AppLockSettingsView extends StatefulWidget {
  const AppLockSettingsView({super.key});

  @override
  State<AppLockSettingsView> createState() => _AppLockSettingsViewState();
}

class _AppLockSettingsViewState extends State<AppLockSettingsView> {
  bool _busy = false;

  Future<AppLockCredentialType?> _chooseMethod({
    AppLockCredentialType? current,
  }) => showAppModalSheet<AppLockCredentialType>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x99000000),
    builder: (sheetContext) => _MethodChooser(
      current: current,
      onSelected: (value) => Navigator.of(sheetContext).pop(value),
    ),
  );

  Future<AppLockAutoLockOption?> _chooseAutoLock({
    required AppLockAutoLockOption current,
  }) => showAppModalSheet<AppLockAutoLockOption>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x99000000),
    builder: (sheetContext) => _AutoLockChooser(
      current: current,
      onSelected: (value) => Navigator.of(sheetContext).pop(value),
    ),
  );

  Future<bool> _openSetup(AppLockCredentialType type) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => AppLockCredentialSetupView(type: type),
        ),
      ) ??
      false;

  Future<bool> _verifyCurrent() async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => const AppLockCredentialVerificationView(),
        ),
      ) ??
      false;

  Future<void> _toggleLock(bool value) async {
    if (_busy) return;
    final controller = context.read<LocalAppLockController>();
    if (value) {
      final type = await _chooseMethod();
      if (!mounted || type == null) return;
      await _openSetup(type);
      return;
    }
    if (!await _verifyCurrent() || !mounted) return;
    setState(() => _busy = true);
    try {
      await controller.disable();
    } catch (_) {
      if (mounted) showToast(context, AppStringKeys.appLockSetupFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeCredential() async {
    final controller = context.read<LocalAppLockController>();
    if (_busy || !await _verifyCurrent() || !mounted) return;
    final type = await _chooseMethod(current: controller.credentialType);
    if (!mounted || type == null) return;
    await _openSetup(type);
  }

  Future<void> _toggleBiometric(bool value) async {
    if (_busy) return;
    final controller = context.read<LocalAppLockController>();
    setState(() => _busy = true);
    try {
      final result = await controller.setBiometricEnabled(
        value,
        localizedReason: AppStrings.t(
          AppStringKeys.appLockBiometricEnableReason,
          {'value1': AppStrings.t(_biometricName(controller.biometricKind))},
        ),
      );
      if (!mounted || result == AppLockBiometricResult.success) return;
      final error = _biometricError(result);
      if (error != null) showToast(context, error);
    } catch (_) {
      if (mounted) showToast(context, AppStringKeys.appLockSetupFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeAutoLock(AppLockAutoLockOption current) async {
    if (_busy) return;
    final option = await _chooseAutoLock(current: current);
    if (!mounted || option == null) return;
    setState(() => _busy = true);
    try {
      await context.read<LocalAppLockController>().setAutoLockOption(option);
    } catch (_) {
      if (mounted) showToast(context, AppStringKeys.appLockSetupFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LocalAppLockController>();
    final type = controller.credentialType;
    final biometricName = _biometricName(controller.biometricKind);
    final destructive = Theme.of(context).colorScheme.error;
    return SettingsPageScaffold(
      title: AppStringKeys.appLockTitle,
      onBack: () => Navigator.of(context).pop(),
      child: SettingsListView(
        children: [
          SettingsCard.rows(
            rows: [
              SettingsSwitchRow(
                title: AppStringKeys.appLockEnabled,
                value: controller.enabled,
                enabled: !_busy,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.lock),
                onChanged: _toggleLock,
              ),
            ],
          ),
          const SettingsNote(text: AppStringKeys.appLockDescription),
          if (controller.enabled) ...[
            const SizedBox(height: AppSpacing.xl),
            SettingsCard.rows(
              rows: [
                SettingsRow(
                  leading: SettingsLeadingIcon(
                    icon: type == AppLockCredentialType.pin
                        ? HeroAppIcons.key
                        : HeroAppIcons.grip,
                  ),
                  title: AppStringKeys.appLockUnlockMethod,
                  value: type == AppLockCredentialType.pin
                      ? AppStringKeys.appLockPin
                      : AppStringKeys.appLockGesture,
                  enabled: !_busy,
                  onTap: _changeCredential,
                ),
                SettingsRow(
                  leading: const SettingsLeadingIcon(
                    icon: HeroAppIcons.arrowsRotate,
                  ),
                  title: type == AppLockCredentialType.pin
                      ? AppStringKeys.appLockChangePin
                      : AppStringKeys.appLockResetGesture,
                  enabled: !_busy,
                  onTap: _changeCredential,
                ),
              ],
            ),
            if (controller.biometricAvailable) ...[
              const SizedBox(height: AppSpacing.xl),
              SettingsCard.rows(
                rows: [
                  SettingsSwitchRow(
                    leading: SettingsLeadingIcon(
                      icon: _biometricIcon(controller.biometricKind),
                    ),
                    title: AppStrings.t(AppStringKeys.appLockUseBiometric, {
                      'value1': AppStrings.t(biometricName),
                    }),
                    value: controller.biometricEnabled,
                    enabled: !_busy,
                    onChanged: _toggleBiometric,
                  ),
                ],
              ),
              SettingsNote(
                text: AppStrings.t(AppStringKeys.appLockBiometricDescription, {
                  'value1': AppStrings.t(biometricName),
                }),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            SettingsCard.rows(
              rows: [
                SettingsRow(
                  leading: const SettingsLeadingIcon(icon: HeroAppIcons.clock),
                  title: AppStringKeys.appLockAutoLock,
                  value: _autoLockLabel(controller.autoLockOption),
                  enabled: !_busy,
                  onTap: () => _changeAutoLock(controller.autoLockOption),
                ),
              ],
            ),
            const SettingsNote(text: AppStringKeys.appLockAutoLockDescription),
            const SizedBox(height: AppSpacing.xl),
            SettingsCard.rows(
              rows: [
                SettingsRow(
                  leading: SettingsLeadingIcon(
                    icon: HeroAppIcons.lock,
                    color: destructive,
                  ),
                  title: AppStringKeys.appLockDisable,
                  titleColor: destructive,
                  enabled: !_busy,
                  showChevron: false,
                  onTap: () => _toggleLock(false),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class AppLockCredentialSetupView extends StatefulWidget {
  const AppLockCredentialSetupView({super.key, required this.type});

  final AppLockCredentialType type;

  @override
  State<AppLockCredentialSetupView> createState() =>
      _AppLockCredentialSetupViewState();
}

class _AppLockCredentialSetupViewState
    extends State<AppLockCredentialSetupView> {
  String? _firstCredential;

  Future<_ChallengeResult> _submit(String credential) async {
    if (_firstCredential == null) {
      setState(() => _firstCredential = credential);
      return const _ChallengeResult.continueFlow();
    }
    if (_firstCredential != credential) {
      return _ChallengeResult.rejected(
        widget.type == AppLockCredentialType.pin
            ? AppStringKeys.appLockPinMismatch
            : AppStringKeys.appLockGestureMismatch,
      );
    }
    try {
      await context.read<LocalAppLockController>().setCredential(
        widget.type,
        credential,
      );
      if (mounted) Navigator.of(context).pop(true);
      return const _ChallengeResult.complete();
    } catch (_) {
      return const _ChallengeResult.rejected(AppStringKeys.appLockSetupFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirm = _firstCredential != null;
    final methodName = widget.type == AppLockCredentialType.pin
        ? AppStringKeys.appLockPin
        : AppStringKeys.appLockGesture;
    final prompt = switch ((widget.type, confirm)) {
      (AppLockCredentialType.pin, false) => AppStringKeys.appLockCreatePin,
      (AppLockCredentialType.pin, true) => AppStringKeys.appLockConfirmPin,
      (AppLockCredentialType.gesture, false) =>
        AppStringKeys.appLockCreateGesture,
      (AppLockCredentialType.gesture, true) =>
        AppStringKeys.appLockConfirmGesture,
    };
    return SettingsPageScaffold(
      title: methodName,
      onBack: () => Navigator.of(context).pop(),
      child: SafeArea(
        top: false,
        child: _CredentialChallenge(
          type: widget.type,
          title: methodName,
          prompt: prompt,
          onSubmit: _submit,
        ),
      ),
    );
  }
}

class AppLockCredentialVerificationView extends StatelessWidget {
  const AppLockCredentialVerificationView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LocalAppLockController>();
    final type = controller.credentialType;
    if (type == null) return const SizedBox.shrink();
    return SettingsPageScaffold(
      title: AppStringKeys.appLockVerifyTitle,
      onBack: () => Navigator.of(context).pop(false),
      child: SafeArea(
        top: false,
        child: _CredentialChallenge(
          type: type,
          title: AppStringKeys.appLockVerifyTitle,
          prompt: type == AppLockCredentialType.pin
              ? AppStringKeys.appLockEnterPin
              : AppStringKeys.appLockDrawGesture,
          biometricKind: controller.biometricKind,
          showBiometric:
              controller.biometricEnabled && controller.biometricAvailable,
          onSubmit: (credential) async {
            final accepted = await controller.verifyCredential(credential);
            if (accepted && context.mounted) {
              Navigator.of(context).pop(true);
            }
            return accepted
                ? const _ChallengeResult.complete()
                : _ChallengeResult.rejected(
                    type == AppLockCredentialType.pin
                        ? AppStringKeys.appLockWrongPin
                        : AppStringKeys.appLockWrongGesture,
                  );
          },
          onBiometric: () async {
            final result = await controller.authenticateBiometric(
              localizedReason: AppStringKeys.appLockBiometricReason.l10n(
                context,
              ),
              unlockOnSuccess: false,
            );
            if (result == AppLockBiometricResult.success && context.mounted) {
              Navigator.of(context).pop(true);
            }
            return _biometricError(result);
          },
        ),
      ),
    );
  }
}

class _CredentialChallenge extends StatefulWidget {
  const _CredentialChallenge({
    required this.type,
    required this.title,
    required this.prompt,
    required this.onSubmit,
    this.leading,
    this.showBiometric = false,
    this.biometricKind = AppLockBiometricKind.generic,
    this.onBiometric,
    this.lockScreenStyle = false,
    this.biometricPending = false,
    this.unlocked = false,
  });

  final AppLockCredentialType type;
  final String title;
  final String prompt;
  final Widget? leading;
  final bool showBiometric;
  final AppLockBiometricKind biometricKind;
  final Future<_ChallengeResult> Function(String credential) onSubmit;
  final Future<String?> Function()? onBiometric;
  final bool lockScreenStyle;
  final bool biometricPending;
  final bool unlocked;

  @override
  State<_CredentialChallenge> createState() => _CredentialChallengeState();
}

class _CredentialChallengeState extends State<_CredentialChallenge>
    with SingleTickerProviderStateMixin {
  static final Map<LogicalKeyboardKey, int> _keyboardDigits = {
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad0: 0,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };

  final FocusNode _keyboardFocusNode = FocusNode(
    debugLabel: 'app-lock-credential-keyboard',
  );

  /// A wrong credential shakes the identity cluster above the keypad, the way
  /// exteraless springs its passcode title. Finite, so widget tests settle.
  late final AnimationController _shake;
  String _pin = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Eager: a lazy controller would be constructed from dispose() when no
    // error ever occurred, and TickerMode lookups are unsafe by then.
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
  }

  @override
  void dispose() {
    _shake.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyboardInput(FocusNode node, KeyEvent event) {
    if (widget.type != AppLockCredentialType.pin ||
        event is! KeyDownEvent ||
        keyboardModifiersPressed() ||
        _busy ||
        widget.unlocked ||
        widget.biometricPending) {
      return KeyEventResult.ignored;
    }

    final digit = _keyboardDigits[event.logicalKey];
    if (digit != null) {
      _addDigit(digit);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _deleteDigit();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget _withKeyboardInput(Widget child) {
    if (widget.type != AppLockCredentialType.pin ||
        widget.biometricPending ||
        widget.unlocked) {
      return child;
    }
    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyboardInput,
      child: child,
    );
  }

  Future<void> _submit(String credential) async {
    if (_busy || widget.biometricPending || widget.unlocked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.onSubmit(credential);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      _error = result.error;
    });
    if (result.error != null) {
      unawaited(AppHaptics.error());
      unawaited(_shake.forward(from: 0));
    }
  }

  void _addDigit(int digit) {
    if (_busy ||
        widget.unlocked ||
        widget.biometricPending ||
        _pin.length >= LocalAppLockController.pinLength) {
      return;
    }
    unawaited(AppHaptics.tap());
    setState(() {
      _error = null;
      _pin += '$digit';
    });
    if (_pin.length == LocalAppLockController.pinLength) {
      final value = _pin;
      unawaited(_submit(value));
    }
  }

  void _deleteDigit() {
    if (_busy || widget.unlocked || widget.biometricPending || _pin.isEmpty) {
      return;
    }
    unawaited(AppHaptics.tap());
    setState(() {
      _error = null;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _submitGesture(List<int> pattern) async {
    if (pattern.length < LocalAppLockController.minimumGestureNodes) {
      setState(() => _error = AppStringKeys.appLockGestureTooShort);
      unawaited(AppHaptics.error());
      unawaited(_shake.forward(from: 0));
      return;
    }
    await _submit(pattern.join(','));
  }

  Future<void> _runBiometric() async {
    final authenticate = widget.onBiometric;
    if (_busy || authenticate == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await authenticate();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error != null) unawaited(_shake.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) => _withKeyboardInput(
    widget.lockScreenStyle
        ? _buildLockScreen(context)
        : _buildCredentialScreen(context),
  );

  Widget _buildCredentialScreen(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, constraints.maxHeight - 50),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ?widget.leading,
              if (widget.leading != null) const SizedBox(height: 18),
              Text(
                widget.title.l10n(context),
                textAlign: TextAlign.center,
                style: AppTextStyle.display(c.textPrimary),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                child: Text(
                  (_error ?? widget.prompt).l10n(context),
                  key: ValueKey(_error ?? widget.prompt),
                  textAlign: TextAlign.center,
                  style: AppTextStyle.body(
                    _error == null ? c.textSecondary : AppTheme.tagRed,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (widget.type == AppLockCredentialType.pin) ...[
                _PinDots(count: _pin.length, error: _error != null),
                const SizedBox(height: 28),
                _PinPad(
                  onDigit: _addDigit,
                  onDelete: _deleteDigit,
                  onBiometric: widget.showBiometric ? _runBiometric : null,
                  biometricKind: widget.biometricKind,
                  enabled: !_busy,
                ),
              ] else ...[
                GesturePatternPad(
                  enabled: !_busy,
                  onCompleted: _submitGesture,
                  error: _error != null,
                ),
                if (widget.showBiometric) ...[
                  const SizedBox(height: 18),
                  _BiometricTextButton(
                    kind: widget.biometricKind,
                    enabled: !_busy,
                    onTap: _runBiometric,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockScreen(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final palette = _AppLockPalette.of(context);
      final prompt = widget.unlocked
          ? AppStringKeys.appLockUnlocked
          : widget.biometricPending
          ? _biometricUnlockName(widget.biometricKind)
          : _error ?? widget.prompt;
      final patternSize = math.min(constraints.maxWidth - 40, 440.0);
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  math.max(28, constraints.maxHeight * 0.055),
                  24,
                  20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Shake(
                      animation: _shake,
                      child: Column(
                        children: [
                          _LockEmblem(
                            error: _error != null && !widget.biometricPending,
                            pending: widget.biometricPending,
                            unlocked: widget.unlocked,
                            biometricKind: widget.biometricKind,
                            child: widget.leading,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            widget.title.l10n(context),
                            textAlign: TextAlign.center,
                            style: AppTextStyle.display(palette.foreground),
                          ),
                          const SizedBox(height: 6),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            child: Text(
                              prompt.l10n(context),
                              key: ValueKey(prompt),
                              textAlign: TextAlign.center,
                              style: AppTextStyle.body(
                                widget.unlocked ||
                                        _error == null ||
                                        widget.biometricPending
                                    ? palette.secondary
                                    : palette.error,
                                weight: AppTextWeight.medium,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (widget.unlocked)
                      _UnlockedCheck(palette: palette)
                    else if (widget.biometricPending)
                      _BiometricWaiting(
                        kind: widget.biometricKind,
                        palette: palette,
                      )
                    else if (widget.type == AppLockCredentialType.pin) ...[
                      _PinDots(
                        count: _pin.length,
                        error: _error != null,
                        lockScreenStyle: true,
                      ),
                      const SizedBox(height: 28),
                      _PinPad(
                        onDigit: _addDigit,
                        onDelete: _deleteDigit,
                        onBiometric: widget.showBiometric
                            ? _runBiometric
                            : null,
                        biometricKind: widget.biometricKind,
                        enabled: !_busy,
                        lockScreenStyle: true,
                      ),
                    ] else ...[
                      SizedBox(
                        width: patternSize,
                        height: patternSize,
                        child: GesturePatternPad(
                          enabled: !_busy,
                          onCompleted: _submitGesture,
                          error: _error != null,
                          lockScreenStyle: true,
                        ),
                      ),
                      if (widget.showBiometric) ...[
                        const SizedBox(height: 16),
                        _BiometricTextButton(
                          kind: widget.biometricKind,
                          enabled: !_busy,
                          onTap: _runBiometric,
                          lockScreenStyle: true,
                        ),
                      ],
                    ],
                    const SizedBox(height: 30),
                    _LockFooter(palette: palette),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A finite horizontal spring, used for a rejected credential. The offset
/// decays to zero, so a rebuild after the animation leaves no residue.
class _Shake extends StatelessWidget {
  const _Shake({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value;
      if (t == 0) return child!;
      final dx = math.sin(t * math.pi * 5) * 11 * (1 - t);
      return Transform.translate(offset: Offset(dx, 0), child: child);
    },
    child: child,
  );
}

/// Profile portrait inside a glass medallion with a lock seal — the identity
/// anchor of the lock screen. Enters with a short spring so the gate never
/// appears as a frozen slab.
class _LockEmblem extends StatefulWidget {
  const _LockEmblem({
    required this.child,
    required this.error,
    required this.pending,
    required this.biometricKind,
    this.unlocked = false,
  });

  final Widget? child;
  final bool error;
  final bool pending;
  final AppLockBiometricKind biometricKind;
  final bool unlocked;

  @override
  State<_LockEmblem> createState() => _LockEmblemState();
}

class _LockEmblemState extends State<_LockEmblem>
    with SingleTickerProviderStateMixin {
  static const double _size = 112;

  late final AnimationController _entrance;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 640),
    );
    _scale = Tween<double>(
      begin: 0.84,
      end: 1,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutBack));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _AppLockPalette.of(context);
    final ringColor = widget.error ? palette.error : palette.accent;
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _LockEmblemRingPainter(
                    color: ringColor,
                    glow: ringColor.withValues(alpha: 0.22),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: AppMotion.responsive,
                width: _size - 16,
                height: _size - 16,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.emblemFill,
                  border: Border.all(
                    color: widget.error ? palette.error : palette.emblemRim,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.20),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipOval(child: widget.child ?? const SizedBox.shrink()),
              ),
              Positioned(
                right: -2,
                bottom: 4,
                child: AnimatedContainer(
                  duration: AppMotion.responsive,
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.unlocked
                        ? palette.accent
                        : widget.error
                        ? palette.error
                        : palette.badgeFill,
                    border: Border.all(
                      color: palette.backdrop.withValues(alpha: 0.65),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.24),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: AppIcon(
                    widget.unlocked
                        ? HeroAppIcons.check
                        : widget.pending
                        ? _biometricIcon(widget.biometricKind)
                        : HeroAppIcons.lock,
                    size: 16,
                    color: widget.unlocked || widget.error || !widget.pending
                        ? Colors.white
                        : palette.accent,
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

class _LockEmblemRingPainter extends CustomPainter {
  const _LockEmblemRingPainter({required this.color, required this.glow});

  final Color color;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = SweepGradient(
          colors: [
            color.withValues(alpha: 0.9),
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.9),
          ],
          stops: const [0, 0.42, 0.72, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..color = glow,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..shader = SweepGradient(
          colors: [
            color.withValues(alpha: 0.95),
            color.withValues(alpha: 0.15),
            color.withValues(alpha: 0.65),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(covariant _LockEmblemRingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.glow != glow;
}

/// The waiting state during a native biometric prompt: the glyph sits in a
/// still halo. A spinner would keep the gate repainting while the OS sheet is
/// up, and an infinite loop also never settles a widget test.
class _BiometricWaiting extends StatelessWidget {
  const _BiometricWaiting({required this.kind, required this.palette});

  final AppLockBiometricKind kind;
  final _AppLockPalette palette;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 116,
    height: 116,
    child: Center(
      child: Container(
        width: 92,
        height: 92,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: palette.emblemFill,
          border: Border.all(color: palette.emblemRim),
          boxShadow: [
            BoxShadow(
              color: palette.accent.withValues(alpha: 0.16),
              blurRadius: 30,
              spreadRadius: 4,
            ),
          ],
        ),
        child: AppIcon(_biometricIcon(kind), size: 42, color: palette.accent),
      ),
    ),
  );
}

/// The confirmation that plays for the 340 ms the gate takes to hand the
/// screen back: the lock plate grows into a check while everything fades.
class _UnlockedCheck extends StatelessWidget {
  const _UnlockedCheck({required this.palette});

  final _AppLockPalette palette;

  @override
  Widget build(BuildContext context) {
    final onAccent =
        ThemeData.estimateBrightnessForColor(palette.accent) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return SizedBox(
      width: 116,
      height: 116,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.82, end: 1),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutBack,
          builder: (context, value, child) =>
              Transform.scale(scale: value, child: child),
          child: Container(
            width: 92,
            height: 92,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.accent,
              boxShadow: [
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.35),
                  blurRadius: 34,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: AppIcon(HeroAppIcons.check, size: 44, color: onAccent),
          ),
        ),
      ),
    );
  }
}

class _LockFooter extends StatelessWidget {
  const _LockFooter({required this.palette});

  final _AppLockPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        BrandMark.ink(ink: 15),
        const SizedBox(width: 7),
        Text('Mithka X', style: AppTextStyle.caption(palette.footer)),
      ],
    );
  }
}

class GesturePatternPad extends StatefulWidget {
  const GesturePatternPad({
    super.key,
    required this.onCompleted,
    this.enabled = true,
    this.error = false,
    this.lockScreenStyle = false,
  });

  final ValueChanged<List<int>> onCompleted;
  final bool enabled;
  final bool error;
  final bool lockScreenStyle;

  @override
  State<GesturePatternPad> createState() => _GesturePatternPadState();
}

class _GesturePatternPadState extends State<GesturePatternPad> {
  final List<int> _selected = [];
  Offset? _pointer;

  List<Offset> _centers(Size size) {
    final cell = size.width / 4;
    return [
      for (var row = 0; row < 3; row += 1)
        for (var column = 0; column < 3; column += 1)
          Offset(cell * (column + 1), cell * (row + 1)),
    ];
  }

  void _update(Offset point, Size size) {
    if (!widget.enabled) return;
    final centers = _centers(size);
    var nearest = -1;
    var distance = double.infinity;
    for (var index = 0; index < centers.length; index += 1) {
      final candidate = (centers[index] - point).distance;
      if (candidate < distance) {
        nearest = index;
        distance = candidate;
      }
    }
    setState(() => _pointer = point);
    final hitRadius = widget.lockScreenStyle
        ? math.max(38.0, size.width / 8)
        : math.max(28.0, size.width / 9);
    if (nearest < 0 || distance > hitRadius) return;
    if (_selected.contains(nearest)) return;
    final intermediate = _intermediateNode(_selected.lastOrNull, nearest);
    if (intermediate != null && !_selected.contains(intermediate)) {
      _selected.add(intermediate);
    }
    _selected.add(nearest);
    unawaited(AppHaptics.tap());
    setState(() {});
  }

  int? _intermediateNode(int? from, int to) {
    if (from == null) return null;
    final fromRow = from ~/ 3;
    final fromColumn = from % 3;
    final toRow = to ~/ 3;
    final toColumn = to % 3;
    final rowDifference = (fromRow - toRow).abs();
    final columnDifference = (fromColumn - toColumn).abs();
    if ((rowDifference == 2 && columnDifference == 0) ||
        (rowDifference == 0 && columnDifference == 2) ||
        (rowDifference == 2 && columnDifference == 2)) {
      return ((fromRow + toRow) ~/ 2) * 3 + ((fromColumn + toColumn) ~/ 2);
    }
    return null;
  }

  void _finish() {
    if (_selected.isEmpty) return;
    final result = List<int>.from(_selected);
    setState(() {
      _selected.clear();
      _pointer = null;
    });
    widget.onCompleted(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final palette = _AppLockPalette.of(context);
    return Semantics(
      label: AppStringKeys.appLockGestureGrid.l10n(context),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.lockScreenStyle ? 480 : 320,
        ),
        child: AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size.square(constraints.maxWidth);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: widget.enabled
                    ? (details) => _update(details.localPosition, size)
                    : null,
                onPanUpdate: widget.enabled
                    ? (details) => _update(details.localPosition, size)
                    : null,
                onPanEnd: widget.enabled ? (_) => _finish() : null,
                onPanCancel: widget.enabled ? _finish : null,
                child: CustomPaint(
                  painter: _GesturePatternPainter(
                    centers: _centers(size),
                    selected: _selected,
                    pointer: _pointer,
                    accent: widget.error
                        ? palette.error
                        : widget.lockScreenStyle
                        ? palette.accent
                        : c.linkBlue,
                    idle: widget.lockScreenStyle
                        ? palette.foreground
                        : c.textTertiary,
                    largeOutlinedNodes: widget.lockScreenStyle,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GesturePatternPainter extends CustomPainter {
  const _GesturePatternPainter({
    required this.centers,
    required this.selected,
    required this.pointer,
    required this.accent,
    required this.idle,
    required this.largeOutlinedNodes,
  });

  final List<Offset> centers;
  final List<int> selected;
  final Offset? pointer;
  final Color accent;
  final Color idle;
  final bool largeOutlinedNodes;

  @override
  void paint(Canvas canvas, Size size) {
    final trail = Path();
    if (selected.isNotEmpty) {
      trail.moveTo(centers[selected.first].dx, centers[selected.first].dy);
      for (final node in selected.skip(1)) {
        trail.lineTo(centers[node].dx, centers[node].dy);
      }
      if (pointer != null) trail.lineTo(pointer!.dx, pointer!.dy);
    }
    if (largeOutlinedNodes) {
      // A blurred under-stroke reads as a soft glow on the glass plate.
      if (selected.length > 1) {
        canvas.drawPath(
          trail,
          Paint()
            ..color = accent.withValues(alpha: 0.28)
            ..strokeWidth = 11
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
        );
      }
      if (selected.length > 1 || (selected.isNotEmpty && pointer != null)) {
        canvas.drawPath(
          trail,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent.withValues(alpha: 0.85), accent],
            ).createShader(Offset.zero & size)
            ..strokeWidth = 3.4
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke,
        );
      }
      for (var index = 0; index < centers.length; index += 1) {
        final isSelected = selected.contains(index);
        final center = centers[index];
        if (isSelected) {
          canvas.drawCircle(
            center,
            40,
            Paint()
              ..color = accent.withValues(alpha: 0.24)
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(
            center,
            32,
            Paint()
              ..color = accent
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke,
          );
          canvas.drawCircle(
            center,
            12,
            Paint()
              ..color = accent
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
          );
          canvas.drawCircle(
            center,
            9,
            Paint()
              ..color = accent
              ..style = PaintingStyle.fill,
          );
        } else {
          canvas.drawCircle(
            center,
            32,
            Paint()
              ..color = idle.withValues(alpha: 0.05)
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(
            center,
            32,
            Paint()
              ..color = idle.withValues(alpha: 0.30)
              ..strokeWidth = 1.6
              ..style = PaintingStyle.stroke,
          );
        }
      }
      return;
    }

    final linePaint = Paint()
      ..color = accent
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (selected.length > 1) {
      final path = Path()
        ..moveTo(centers[selected.first].dx, centers[selected.first].dy);
      for (final node in selected.skip(1)) {
        path.lineTo(centers[node].dx, centers[node].dy);
      }
      canvas.drawPath(path, linePaint);
    }
    if (selected.isNotEmpty && pointer != null) {
      canvas.drawLine(centers[selected.last], pointer!, linePaint);
    }
    for (var index = 0; index < centers.length; index += 1) {
      final isSelected = selected.contains(index);
      canvas.drawCircle(
        centers[index],
        isSelected ? 12 : 10,
        Paint()
          ..color = isSelected ? accent : idle.withValues(alpha: 0.28)
          ..style = PaintingStyle.fill,
      );
      if (!isSelected) {
        canvas.drawCircle(
          centers[index],
          10,
          Paint()
            ..color = idle.withValues(alpha: 0.72)
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GesturePatternPainter oldDelegate) =>
      oldDelegate.selected != selected ||
      oldDelegate.pointer != pointer ||
      oldDelegate.accent != accent ||
      oldDelegate.idle != idle ||
      oldDelegate.largeOutlinedNodes != largeOutlinedNodes;
}

class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.count,
    required this.error,
    this.lockScreenStyle = false,
  });

  final int count;
  final bool error;
  final bool lockScreenStyle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final palette = _AppLockPalette.of(context);
    final filledColor = error
        ? palette.error
        : lockScreenStyle
        ? palette.accent
        : c.linkBlue;
    final idleColor = error
        ? palette.error
        : lockScreenStyle
        ? palette.foreground.withValues(alpha: 0.55)
        : c.textTertiary;
    final size = lockScreenStyle ? 15.0 : 13.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (
          var index = 0;
          index < LocalAppLockController.pinLength;
          index += 1
        ) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: index < count ? filledColor : Colors.transparent,
              gradient: index < count && lockScreenStyle && !error
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [palette.accentSoft, palette.accent],
                    )
                  : null,
              border: index < count
                  ? null
                  : Border.all(color: idleColor, width: 1.5),
              boxShadow: index < count && lockScreenStyle
                  ? [
                      BoxShadow(
                        color: filledColor.withValues(alpha: 0.45),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
          ),
          if (index != LocalAppLockController.pinLength - 1)
            SizedBox(width: lockScreenStyle ? 17 : 15),
        ],
      ],
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.onDigit,
    required this.onDelete,
    required this.onBiometric,
    required this.biometricKind,
    required this.enabled,
    this.lockScreenStyle = false,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onDelete;
  final VoidCallback? onBiometric;
  final AppLockBiometricKind biometricKind;
  final bool enabled;
  final bool lockScreenStyle;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 276,
    child: Column(
      children: [
        for (var row = 0; row < 3; row += 1) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var column = 0; column < 3; column += 1)
                _NumberKey(
                  number: row * 3 + column + 1,
                  enabled: enabled,
                  onTap: onDigit,
                  lockScreenStyle: lockScreenStyle,
                ),
            ],
          ),
          SizedBox(height: lockScreenStyle ? 16 : 14),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _PadIconButton(
              icon: _biometricIcon(biometricKind),
              enabled: enabled && onBiometric != null,
              onTap: onBiometric,
              lockScreenStyle: lockScreenStyle,
            ),
            _NumberKey(
              number: 0,
              enabled: enabled,
              onTap: onDigit,
              lockScreenStyle: lockScreenStyle,
            ),
            _PadIconButton(
              icon: HeroAppIcons.backspace,
              enabled: enabled,
              onTap: onDelete,
              lockScreenStyle: lockScreenStyle,
            ),
          ],
        ),
      ],
    ),
  );
}

/// Press feedback shared by the digits and the two end keys: a short scale
/// dip under the finger. GestureDetector's tap cancels still reset it.
class _PressableKey extends StatefulWidget {
  const _PressableKey({
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final bool enabled;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_PressableKey> createState() => _PressableKeyState();
}

class _PressableKeyState extends State<_PressableKey> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
    onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
    onTapCancel: widget.enabled ? () => _setPressed(false) : null,
    onTap: widget.enabled ? widget.onTap : null,
    child: AnimatedScale(
      scale: _pressed ? 0.93 : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: widget.enabled ? 1 : 0.45,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    ),
  );
}

/// The circular key plate. On the lock screen it is a glass disc: a translucent
/// fill, a top sheen and a hairline rim, sitting on a soft shadow.
class _KeySurface extends StatelessWidget {
  const _KeySurface({
    required this.size,
    required this.lockScreenStyle,
    required this.child,
  });

  final double size;
  final bool lockScreenStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!lockScreenStyle) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.card,
          border: Border.all(color: c.divider),
        ),
        child: child,
      );
    }
    final palette = _AppLockPalette.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.keyFillTop, palette.keyFillBottom],
        ),
        border: Border.all(color: palette.keyRim),
        boxShadow: [
          BoxShadow(
            color: palette.keyShadow,
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: FractionallySizedBox(
                heightFactor: 0.52,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette.keySheen,
                        palette.keySheen.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Center(child: child),
          ],
        ),
      ),
    );
  }
}

class _NumberKey extends StatelessWidget {
  const _NumberKey({
    required this.number,
    required this.enabled,
    required this.onTap,
    this.lockScreenStyle = false,
  });

  final int number;
  final bool enabled;
  final ValueChanged<int> onTap;
  final bool lockScreenStyle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final palette = _AppLockPalette.of(context);
    return Semantics(
      button: true,
      label: '$number',
      child: _PressableKey(
        enabled: enabled,
        onTap: () => onTap(number),
        child: _KeySurface(
          size: 72,
          lockScreenStyle: lockScreenStyle,
          child: Text(
            '$number',
            style: TextStyle(
              color: lockScreenStyle ? palette.foreground : c.textPrimary,
              fontSize: 28,
              fontWeight: AppTextWeight.medium,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _PadIconButton extends StatelessWidget {
  const _PadIconButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
    this.lockScreenStyle = false,
  });

  final AppIconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final bool lockScreenStyle;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return const SizedBox(width: 72, height: 72);
    }
    final palette = _AppLockPalette.of(context);
    return Semantics(
      button: true,
      child: _PressableKey(
        enabled: enabled,
        onTap: onTap,
        child: _KeySurface(
          size: 72,
          lockScreenStyle: lockScreenStyle,
          child: AppIcon(
            icon,
            size: 26,
            color: lockScreenStyle
                ? palette.foreground
                : context.colors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _BiometricTextButton extends StatelessWidget {
  const _BiometricTextButton({
    required this.kind,
    required this.enabled,
    required this.onTap,
    this.lockScreenStyle = false,
  });

  final AppLockBiometricKind kind;
  final bool enabled;
  final VoidCallback onTap;
  final bool lockScreenStyle;

  @override
  Widget build(BuildContext context) {
    final name = _biometricName(kind);
    final palette = _AppLockPalette.of(context);
    final accent = lockScreenStyle ? palette.accent : context.colors.linkBlue;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: lockScreenStyle
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: palette.keyRim),
                  color: palette.keyFillBottom.withValues(alpha: 0.6),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(_biometricIcon(kind), size: 22, color: accent),
              const SizedBox(width: 8),
              Text(
                AppStrings.t(AppStringKeys.appLockTryBiometric, {
                  'value1': AppStrings.t(name),
                }),
                style: AppTextStyle.bodyLarge(accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodChooser extends StatelessWidget {
  const _MethodChooser({required this.current, required this.onSelected});

  final AppLockCredentialType? current;
  final ValueChanged<AppLockCredentialType> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStringKeys.appLockChooseMethod.l10n(context),
              style: AppTextStyle.title(
                c.textPrimary,
                weight: AppTextWeight.semibold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStringKeys.appLockChooseMethodDescription.l10n(context),
              style: AppTextStyle.body(c.textSecondary),
            ),
            const SizedBox(height: 14),
            _MethodChoice(
              icon: HeroAppIcons.key,
              title: AppStringKeys.appLockPin,
              detail: AppStringKeys.appLockPinDescription,
              selected: current == AppLockCredentialType.pin,
              onTap: () => onSelected(AppLockCredentialType.pin),
            ),
            const SizedBox(height: 8),
            _MethodChoice(
              icon: HeroAppIcons.grip,
              title: AppStringKeys.appLockGesture,
              detail: AppStringKeys.appLockGestureDescription,
              selected: current == AppLockCredentialType.gesture,
              onTap: () => onSelected(AppLockCredentialType.gesture),
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoLockChooser extends StatelessWidget {
  const _AutoLockChooser({required this.current, required this.onSelected});

  final AppLockAutoLockOption current;
  final ValueChanged<AppLockAutoLockOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStringKeys.appLockAutoLock.l10n(context),
              style: AppTextStyle.title(
                c.textPrimary,
                weight: AppTextWeight.semibold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStringKeys.appLockAutoLockDescription.l10n(context),
              style: AppTextStyle.body(c.textSecondary),
            ),
            const SizedBox(height: 14),
            for (final option in AppLockAutoLockOption.values) ...[
              _MethodChoice(
                icon: HeroAppIcons.clock,
                title: _autoLockLabel(option),
                detail: null,
                selected: current == option,
                onTap: () => onSelected(option),
              ),
              if (option != AppLockAutoLockOption.values.last)
                const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _MethodChoice extends StatelessWidget {
  const _MethodChoice({
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final AppIconData icon;
  final String title;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? c.linkBlue.withValues(alpha: 0.10)
              : c.groupedBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? c.linkBlue : c.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            AppIcon(icon, size: 24, color: c.linkBlue),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.l10n(context),
                    style: AppTextStyle.title(c.textPrimary),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      detail!.l10n(context),
                      style: AppTextStyle.footnote(c.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              AppIcon(HeroAppIcons.check, size: 20, color: c.linkBlue),
          ],
        ),
      ),
    );
  }
}

String _autoLockLabel(AppLockAutoLockOption option) => switch (option) {
  AppLockAutoLockOption.disabled => AppStringKeys.appLockAutoLockDisabled,
  AppLockAutoLockOption.immediately => AppStringKeys.appLockAutoLockImmediately,
  AppLockAutoLockOption.oneMinute => AppStringKeys.appLockAutoLockOneMinute,
  AppLockAutoLockOption.fiveMinutes => AppStringKeys.appLockAutoLockFiveMinutes,
  AppLockAutoLockOption.oneHour => AppStringKeys.appLockAutoLockOneHour,
  AppLockAutoLockOption.fiveHours => AppStringKeys.appLockAutoLockFiveHours,
};

@immutable
class _ChallengeResult {
  const _ChallengeResult.complete() : error = null;
  const _ChallengeResult.continueFlow() : error = null;
  const _ChallengeResult.rejected(this.error);

  final String? error;
}

AppIconData _biometricIcon(AppLockBiometricKind kind) =>
    kind == AppLockBiometricKind.face
    ? HeroAppIcons.faceScan
    : HeroAppIcons.fingerprint;

String _biometricUnlockName(AppLockBiometricKind kind) => switch (kind) {
  AppLockBiometricKind.face => AppStringKeys.appLockFaceUnlock,
  AppLockBiometricKind.fingerprint => AppStringKeys.appLockFingerprintUnlock,
  AppLockBiometricKind.generic => AppStringKeys.appLockBiometricUnlock,
};

String _biometricName(AppLockBiometricKind kind) => switch (kind) {
  AppLockBiometricKind.face => AppStringKeys.appLockFaceId,
  AppLockBiometricKind.fingerprint => AppStringKeys.appLockFingerprint,
  AppLockBiometricKind.generic => AppStringKeys.appLockBiometrics,
};

String? _biometricError(AppLockBiometricResult result) => switch (result) {
  AppLockBiometricResult.success || AppLockBiometricResult.canceled => null,
  AppLockBiometricResult.unavailable =>
    AppStringKeys.appLockBiometricUnavailable,
  AppLockBiometricResult.lockedOut => AppStringKeys.appLockBiometricLockedOut,
  AppLockBiometricResult.failed => AppStringKeys.appLockBiometricFailed,
};
