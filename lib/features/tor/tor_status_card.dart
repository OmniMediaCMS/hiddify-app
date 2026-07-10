import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/tor/tor_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class TorStatusCard extends HookConsumerWidget {
  const TorStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final torEnabled = ref.watch(Preferences.torEnabled);
    if (!torEnabled) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final status = ref.watch(torStatusProvider).valueOrNull ?? const TorConnectionStatus.disabled();
    final exitInfo = ref.watch(torExitInfoProvider);
    final phase = _phaseText(status);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.security_rounded, color: _statusColor(theme, status), size: 28),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Tor', style: theme.textTheme.titleMedium),
                    const Gap(2),
                    Text(
                      status.isPending ? '$phase ${status.bootstrapPercent}%' : phase,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (status.summary.isNotEmpty && !status.isConnected) ...[
                      const Gap(2),
                      Text(
                        status.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (status.isConnected)
                exitInfo.when(
                  data: (info) => info == null
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(info.city.isEmpty ? info.countryCode : info.city, style: theme.textTheme.titleSmall),
                            const Gap(2),
                            Text(
                              '${info.latency.inMilliseconds} ms',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                  error: (_, _) => Text('Latency unavailable', style: theme.textTheme.bodySmall),
                  loading: () =>
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _phaseText(TorConnectionStatus status) => switch (status.phase) {
    TorConnectionPhase.disabled => 'Disabled',
    TorConnectionPhase.starting => 'Starting',
    TorConnectionPhase.connecting => 'Connecting',
    TorConnectionPhase.connected => 'Connected',
    TorConnectionPhase.failed => 'Failed',
    TorConnectionPhase.stopping => 'Stopping',
  };

  Color _statusColor(ThemeData theme, TorConnectionStatus status) => switch (status.phase) {
    TorConnectionPhase.connected => Colors.green,
    TorConnectionPhase.failed => theme.colorScheme.error,
    TorConnectionPhase.starting ||
    TorConnectionPhase.connecting ||
    TorConnectionPhase.stopping => theme.colorScheme.primary,
    TorConnectionPhase.disabled => theme.colorScheme.onSurfaceVariant,
  };
}
