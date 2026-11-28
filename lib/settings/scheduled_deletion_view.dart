//
//  scheduled_deletion_view.dart
//
//  Settings › Privacy & Security › Scheduled deletion. One master switch and
//  the delay choice; the controller behind it deletes this account's messages
//  in groups that have no server-side auto-delete timer.
//

import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/group_scheduled_deletion.dart';
import '../components/app_icons.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';

class ScheduledDeletionSettingsView extends StatelessWidget {
  const ScheduledDeletionSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = GroupScheduledDeletionController.shared;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SettingsPageScaffold(
        title: AppStrings.t(AppStringKeys.mithkaxScheduledDeleteTitle),
        onBack: () => Navigator.of(context).pop(),
        child: SettingsListView(
          children: [
            SettingsSwitchRow(
              key: const ValueKey('scheduled-delete-master'),
              title: AppStringKeys.mithkaxScheduledDeleteEnable,
              subtitle: AppStringKeys.mithkaxScheduledDeleteDescription,
              value: controller.enabled,
              leading: const SettingsLeadingIcon(icon: HeroAppIcons.stopwatch),
              onChanged: (value) => unawaited(controller.setEnabled(value)),
            ),
            SettingsSection(
              titleKey: AppStringKeys.mithkaxScheduledDeleteDuration,
              rows: [
                for (final seconds
                    in GroupScheduledDeletionController.durationOptionsSeconds)
                  SettingsRow(
                    key: ValueKey('scheduled-delete-$seconds'),
                    title: GroupScheduledDeletionController.durationLabelKey(
                      seconds,
                    ),
                    showChevron: false,
                    onTap: () =>
                        unawaited(controller.setDurationSeconds(seconds)),
                    trailing: controller.durationSeconds == seconds
                        ? const AppIcon(HeroAppIcons.check, size: 18)
                        : null,
                  ),
              ],
            ),
            const SettingsNote(text: AppStringKeys.mithkaxScheduledDeleteNote),
          ],
        ),
      ),
    );
  }
}
