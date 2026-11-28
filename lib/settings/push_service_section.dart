//
//  push_service_section.dart
//
//  The Android push transport picker on the notification settings screen:
//  in-app keep-alive, Google FCM, UnifiedPush and microG, plus the UnifiedPush
//  gateway and the resident-notification switch. Exteraless's Push Service
//  Type block is the reference.
//

import 'dart:async';

import 'package:flutter/material.dart';

import '../components/app_icons.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../notifications/push_device_registrar.dart';
import '../notifications/push_service_settings.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'profile_account/edit_field_view.dart';

class PushServiceSection extends StatefulWidget {
  const PushServiceSection({super.key});

  @override
  State<PushServiceSection> createState() => _PushServiceSectionState();
}

class _PushServiceSectionState extends State<PushServiceSection> {
  static const _kindOrder = [
    PushServiceKind.inApp,
    PushServiceKind.fcm,
    PushServiceKind.microG,
    PushServiceKind.unifiedPush,
  ];

  final PushServiceSettings _settings = PushServiceSettings.shared;
  final PushServiceStatus _status = PushServiceStatus.shared;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_changed);
    _status.addListener(_changed);
    unawaited(_settings.ensureInitialized());
  }

  @override
  void dispose() {
    _settings.removeListener(_changed);
    _status.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _label(PushServiceKind kind) => AppStrings.t(kind.l10nKey);

  String _description(PushServiceKind kind) => AppStrings.t(switch (kind) {
    PushServiceKind.inApp => 'mithkaxPushServiceInAppDescription',
    PushServiceKind.fcm => 'mithkaxPushServiceFcmDescription',
    PushServiceKind.unifiedPush => 'mithkaxPushServiceUnifiedDescription',
    PushServiceKind.microG => 'mithkaxPushServiceMicroGDescription',
  });

  String get _statusText {
    if (_status.error == 'no_distributor' ||
        _status.error == 'unified_unavailable') {
      return AppStrings.t('mithkaxPushServiceStatusNoDistributor');
    }
    if (_status.error == 'fcm_unavailable' ||
        _status.error == 'registration_failed') {
      return AppStrings.t('mithkaxPushServiceStatusUnavailable');
    }
    if (_settings.kind == PushServiceKind.inApp) {
      return AppStrings.t('mithkaxPushServiceStatusActive');
    }
    if (_status.registered) {
      return AppStrings.t('mithkaxPushServiceStatusActive');
    }
    if (_status.keepAlive) {
      return AppStrings.t('mithkaxPushServiceStatusFallback');
    }
    return AppStrings.t('mithkaxPushServiceStatusRegistering');
  }

  bool get _hasError => _status.error != null;

  Future<void> _retry() async {
    await PushDeviceRegistrar.shared.retry();
  }

  Future<void> _pickKind() async {
    final selected = await showAppModalSheet<PushServiceKind>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        child: SettingsCard(
          children: [
            for (final kind in _kindOrder)
              SettingsRow(
                key: ValueKey('mithkax-push-kind-${kind.name}'),
                title: _label(kind),
                subtitle: _description(kind),
                subtitleMaxLines: null,
                leading: SettingsLeadingIcon(
                  icon: switch (kind) {
                    PushServiceKind.inApp => HeroAppIcons.towerBroadcast,
                    PushServiceKind.fcm => HeroAppIcons.cloud,
                    PushServiceKind.unifiedPush => HeroAppIcons.paperPlane,
                    PushServiceKind.microG => HeroAppIcons.server,
                  },
                ),
                trailing: kind == _settings.kind
                    ? AppIcon(
                        HeroAppIcons.check,
                        size: AppIconSize.md,
                        color: AppTheme.brand,
                      )
                    : null,
                showChevron: false,
                onTap: () => Navigator.of(sheetContext).pop(kind),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == _settings.kind) return;
    await _settings.setKind(selected);
  }

  Future<void> _editGateway() async {
    final value = await Navigator.of(context).push<String>(
      AppPageRoute<String>(
        pageBuilder: (_, _, _) => EditFieldView(
          title: AppStrings.t('mithkaxPushServiceGateway'),
          initial: _settings.gatewayDisplay,
          keyboardType: TextInputType.url,
        ),
      ),
    );
    if (value == null) return;
    await _settings.setGateway(value);
  }

  @override
  Widget build(BuildContext context) {
    final kind = _settings.kind;
    return Column(
      key: const ValueKey('mithkax-push-service-section'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsSection(
          titleKey: 'mithkaxPushServiceTitle',
          rows: [
            SettingsRow(
              key: const ValueKey('mithkax-push-service-mode'),
              title: AppStrings.t('mithkaxPushServiceMode'),
              value: _label(kind),
              leading: const SettingsLeadingIcon(
                icon: HeroAppIcons.towerBroadcast,
              ),
              onTap: _pickKind,
            ),
            if (kind == PushServiceKind.inApp)
              SettingsSwitchRow(
                key: const ValueKey('mithkax-push-resident-notification'),
                title: AppStrings.t('mithkaxPushServiceResident'),
                value: _settings.residentNotification,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.bell),
                onChanged: (value) =>
                    unawaited(_settings.setResidentNotification(value)),
              ),
            if (kind == PushServiceKind.unifiedPush) ...[
              SettingsRow(
                key: const ValueKey('mithkax-push-gateway'),
                title: AppStrings.t('mithkaxPushServiceGateway'),
                value: _settings.gatewayDisplay,
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.link),
                onTap: _editGateway,
              ),
              SettingsRow(
                key: const ValueKey('mithkax-push-distributor'),
                title: AppStrings.t('mithkaxPushServiceDistributor'),
                value:
                    _status.distributor ??
                    AppStrings.t('mithkaxPushServiceDistributorUnset'),
                leading: const SettingsLeadingIcon(icon: HeroAppIcons.server),
                showChevron: false,
              ),
            ],
            SettingsRow(
              key: const ValueKey('mithkax-push-service-status'),
              title: AppStrings.t('mithkaxPushServiceStatus'),
              value: _statusText,
              leading: const SettingsLeadingIcon(icon: HeroAppIcons.circleInfo),
              showChevron: false,
            ),
            if (_hasError)
              SettingsRow(
                key: const ValueKey('mithkax-push-service-retry'),
                title: AppStrings.t('mithkaxPushServiceRetry'),
                leading: const SettingsLeadingIcon(
                  icon: HeroAppIcons.arrowsRotate,
                ),
                showChevron: false,
                onTap: () => unawaited(_retry()),
              ),
          ],
        ),
        SettingsNote(text: AppStrings.t('mithkaxPushServiceRestartNote')),
      ],
    );
  }
}
