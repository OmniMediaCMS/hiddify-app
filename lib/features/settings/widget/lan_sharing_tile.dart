import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Future<String?> _getSharingIp(WidgetRef ref) async {
  final interfaceIp = await _getLanIpFromInterfaces();
  if (interfaceIp != null) return interfaceIp;

  final ipResult = await ref.read(hiddifyCoreServiceProvider).getLANIP().run();
  final coreIp = ipResult.fold((_) => null, (r) => r.ip.trim());
  return coreIp != null && coreIp.isNotEmpty ? coreIp : null;
}

Future<String?> _getLanIpFromInterfaces() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);

  final candidates = <({int rank, String ip})>[];
  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    if (_isVirtualOrCellularInterface(name)) continue;

    for (final address in interface.addresses) {
      final ip = address.address;
      if (!_isPrivateIpv4(ip)) continue;
      candidates.add((rank: _interfaceRank(name), ip: ip));
    }
  }

  candidates.sort((a, b) => a.rank.compareTo(b.rank));
  return candidates.isEmpty ? null : candidates.first.ip;
}

bool _isVirtualOrCellularInterface(String name) {
  return name == 'lo' ||
      name.startsWith('tun') ||
      name.startsWith('tap') ||
      name.startsWith('utun') ||
      name.startsWith('vpn') ||
      name.startsWith('ppp') ||
      name.startsWith('rmnet') ||
      name.startsWith('ccmni') ||
      name.startsWith('clat') ||
      name.startsWith('dummy');
}

int _interfaceRank(String name) {
  if (name.startsWith('wlan') || name.startsWith('wifi')) return 0;
  if (name.startsWith('eth') || name.startsWith('en')) return 1;
  if (name.startsWith('ap') || name.contains('hotspot')) return 2;
  return 3;
}

bool _isPrivateIpv4(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null || part < 0 || part > 255)) return false;
  final first = parts[0]!;
  final second = parts[1]!;
  return first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168);
}

class LanSharingPreferenceWidget extends HookConsumerWidget {
  const LanSharingPreferenceWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    Future<String?> getSharingLink({required bool tor}) async {
      final ip = await _getSharingIp(ref);
      if (ip == null) {
        ref.read(inAppNotificationControllerProvider).showErrorToast(t.pages.settings.inbound.lanIPError);
        return null;
      }
      final port = tor ? ref.read(ConfigOptions.torSharingPort) : ref.read(ConfigOptions.mixedPort);
      final password = tor ? ref.read(ConfigOptions.torSharingPassword) : ref.read(ConfigOptions.lanSharingPassword);
      if (password.isEmpty) {
        return 'socks://$ip:$port';
      } else {
        return 'socks://hiddify:$password@$ip:$port';
      }
    }

    Widget sharingActions({required String qrTitle, required bool tor}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: () async {
                  final link = await getSharingLink(tor: tor);
                  if (link != null) {
                    await Clipboard.setData(ClipboardData(text: link));
                    ref
                        .read(inAppNotificationControllerProvider)
                        .showSuccessToast(t.common.msg.export.clipboard.success);
                  }
                },
                icon: Icon(Icons.link_rounded, color: theme.colorScheme.primary),
                label: Text(
                  t.pages.settings.inbound.copyLink,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final link = await getSharingLink(tor: tor);
                  if (link != null) {
                    final qrLink = '#profile-title: $qrTitle\n$link#$qrTitle';
                    await ref.read(dialogNotifierProvider.notifier).showQrCode(qrLink, message: link);
                  }
                },
                icon: Icon(Icons.qr_code_rounded, color: theme.colorScheme.primary),
                label: Text(
                  t.pages.settings.inbound.qrCode,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
        ],
      );
    }

    Widget sharingTile({
      required String title,
      required String passwordTitle,
      required IconData icon,
      required bool tor,
      required bool enabled,
      required String password,
      required ValueChanged<bool> onChanged,
      required VoidCallback onReset,
      required Future<void> Function(String) onPasswordChanged,
    }) {
      Future<void> editPassword() async {
        final inputValue = await ref
            .read(dialogNotifierProvider.notifier)
            .showSettingInput(title: passwordTitle, initialValue: password, onReset: onReset);
        if (inputValue != null) {
          await onPasswordChanged(inputValue);
        }
      }

      return InkWell(
        onTap: editPassword,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 16, top: 8, bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 12), child: Icon(icon)),
              const Gap(16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
                        Switch.adaptive(value: enabled, onChanged: onChanged),
                      ],
                    ),
                    Text(password.isEmpty ? t.pages.settings.inbound.lanSharingPasswordNotSet : password),
                    if (enabled) ...[const Gap(12), sharingActions(qrTitle: title, tor: tor)],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        sharingTile(
          title: 'VPN sharing',
          passwordTitle: t.pages.settings.inbound.lanSharingPassword,
          icon: Icons.share_rounded,
          tor: false,
          enabled: ref.watch(ConfigOptions.allowConnectionFromLan),
          password: ref.watch(ConfigOptions.lanSharingPassword),
          onChanged: ref.read(ConfigOptions.allowConnectionFromLan.notifier).update,
          onReset: ref.read(ConfigOptions.lanSharingPassword.notifier).reset,
          onPasswordChanged: ref.read(ConfigOptions.lanSharingPassword.notifier).update,
        ),
        if (ref.watch(Preferences.torEnabled))
          sharingTile(
            title: 'Tor sharing',
            passwordTitle: 'Tor sharing password',
            icon: Icons.security_rounded,
            tor: true,
            enabled: ref.watch(ConfigOptions.enableTorSharing),
            password: ref.watch(ConfigOptions.torSharingPassword),
            onChanged: ref.read(ConfigOptions.enableTorSharing.notifier).update,
            onReset: ref.read(ConfigOptions.torSharingPassword.notifier).reset,
            onPasswordChanged: ref.read(ConfigOptions.torSharingPassword.notifier).update,
          ),
      ],
    );
  }
}
