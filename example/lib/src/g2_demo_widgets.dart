part of '../main.dart';

// BLE reconnect demo presentation layer.
//
// This file intentionally contains only widgets and display helpers. Keeping UI
// away from the BLE/auth flow makes the example easier to review when reconnect
// behavior changes.

/// Scan screen header for the reconnect demo.
class _ScanHeader extends StatelessWidget {
  const _ScanHeader({
    required this.platformVersion,
    required this.bleState,
    required this.configs,
    required this.scanning,
    required this.connecting,
    required this.onAddConfig,
    required this.onDeleteConfig,
    required this.onStartScan,
    required this.onStopScan,
  });

  final String platformVersion;
  final String bleState;
  final List<BleConfig> configs;
  final bool scanning;
  final bool connecting;
  final VoidCallback onAddConfig;
  final ValueChanged<String> onDeleteConfig;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;

  @override
  Widget build(BuildContext context) {
    // The header is deliberately configuration-only; connect state is shown in
    // scan rows and detail page so the top controls stay predictable.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BLE Config:', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (configs.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: connecting ? null : onAddConfig,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Config'),
                ),
              )
            else ...[
              for (final config in configs)
                _BleConfigRow(
                  config: config,
                  connecting: connecting,
                  onInfo: () => _showBleConfigInfoDialog(context, config),
                  onDelete: () => onDeleteConfig(config.name),
                ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: connecting ? null : onAddConfig,
                icon: const Icon(Icons.add),
                label: const Text('Add Config'),
              ),
            ],
            const SizedBox(height: 8),
            Text(platformVersion, style: Theme.of(context).textTheme.bodySmall),
            Text('BLE: $bleState',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: connecting || scanning || configs.isEmpty
                        ? null
                        : onStartScan,
                    icon: const Icon(Icons.radar),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: connecting || !scanning ? null : onStopScan,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
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

/// One cached runtime BLE config row inside the scan header.
class _BleConfigRow extends StatelessWidget {
  const _BleConfigRow({
    required this.config,
    required this.connecting,
    required this.onInfo,
    required this.onDelete,
  });

  final BleConfig config;
  final bool connecting;
  final VoidCallback onInfo;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(config.name),
      subtitle: Text(
        'matchCount=${config.scan.matchCount}  |  autoReconnect=${config.autoReconnect}',
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            onPressed: onInfo,
            icon: const Icon(Icons.info_outline),
            tooltip: 'Config info',
          ),
          IconButton(
            onPressed: connecting ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete config',
          ),
        ],
      ),
    );
  }
}

/// Home empty state shown before a BLE device has been added.
class _EmptyDeviceHome extends StatelessWidget {
  const _EmptyDeviceHome({required this.onAddDevice});

  final ValueChanged<BuildContext> onAddDevice;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth_searching,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'No device added',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => onAddDevice(context),
              icon: const Icon(Icons.add),
              label: const Text('Add device'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Search page used for adding a BLE device from any cached config.
class _SearchPage extends StatelessWidget {
  const _SearchPage({
    required this.platformVersion,
    required this.bleState,
    required this.scanning,
    required this.connecting,
    required this.activeConfigs,
    required this.requiredMatchCount,
    required this.scanResults,
    required this.selectedDevice,
    required this.stateVersion,
    required this.onStartScan,
    required this.onStopScan,
    required this.onSaveConfig,
    required this.onDeleteConfig,
    required this.onConnect,
  });

  final String platformVersion;
  final String bleState;
  final bool Function() scanning;
  final bool Function() connecting;
  final List<BleConfig> Function() activeConfigs;
  final int Function(BleMatchDevice match) requiredMatchCount;
  final List<BleMatchDevice> scanResults;
  final BleMatchDevice? Function() selectedDevice;
  final ValueListenable<int> stateVersion;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;
  final Future<void> Function(String rawJson) onSaveConfig;
  final ValueChanged<String> onDeleteConfig;
  final ValueChanged<BleMatchDevice> onConnect;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add BLE Device')),
      body: SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: stateVersion,
          builder: (context, _, __) {
            final configs = activeConfigs();
            void openConfigDialog() {
              _showBleConfigDialog(
                context,
                initialJson: '',
                onSaveConfig: onSaveConfig,
              );
            }

            final selectedUuids = selectedDevice()
                    ?.devices
                    .map((device) => device.uuid)
                    .toSet() ??
                {};
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _ScanHeader(
                    platformVersion: platformVersion,
                    bleState: bleState,
                    configs: configs,
                    scanning: scanning(),
                    connecting: connecting(),
                    onAddConfig: openConfigDialog,
                    onDeleteConfig: onDeleteConfig,
                    onStartScan: onStartScan,
                    onStopScan: onStopScan,
                  ),
                ),
                Expanded(
                  child: configs.isEmpty
                      ? const Center(
                          child: Text('Add a BLE config to start scanning'),
                        )
                      : scanResults.isEmpty
                          ? const Center(child: Text('No BLE devices found'))
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              itemCount: scanResults.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final item = scanResults[index];
                                final isSelected = item.devices.any(
                                  (device) =>
                                      selectedUuids.contains(device.uuid),
                                );
                                return _ScanResultTile(
                                  match: item,
                                  requiredMatchCount: requiredMatchCount(item),
                                  enabled: !connecting(),
                                  connecting: connecting() && isSelected,
                                  onTap: () => onConnect(item),
                                );
                              },
                            ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One scan-result row. Multi-advertisement devices become connectable after
/// the matched count reaches the scan rule configured for that result.
class _ScanResultTile extends StatelessWidget {
  const _ScanResultTile({
    required this.match,
    required this.requiredMatchCount,
    required this.enabled,
    required this.connecting,
    required this.onTap,
  });

  final BleMatchDevice match;
  final int requiredMatchCount;
  final bool enabled;
  final bool connecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final legs = _sortedG2Legs(match.devices);
    // The plugin can match both single-advertisement devices and paired
    // devices. Keep partial rows visible for debugging, but prevent taps until
    // the config-specific matchCount is satisfied.
    final paired = match.devices.length >= requiredMatchCount;
    return Card(
      child: ListTile(
        enabled: enabled && paired,
        onTap: enabled && paired ? onTap : null,
        title: Text('SN: ${match.sn}'),
        subtitle: Text(
          legs.indexed
              .map((entry) => _formatG2Leg(entry.$2, entry.$1))
              .join('\n'),
        ),
        trailing: connecting
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('${match.devices.length}/$requiredMatchCount'),
      ),
    );
  }
}

Future<void> _showBleConfigDialog(
  BuildContext context, {
  required String initialJson,
  required Future<void> Function(String rawJson) onSaveConfig,
}) async {
  return showDialog<void>(
    context: context,
    builder: (context) => _BleConfigDialog(
      initialJson: initialJson,
      onSaveConfig: onSaveConfig,
    ),
  );
}

Future<void> _showBleConfigInfoDialog(
  BuildContext context,
  BleConfig config,
) async {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(config.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('matchCount: ${config.scan.matchCount}'),
            Text('filters: ${config.scan.nameFilters.join(', ')}'),
            Text('services: ${config.privateServices.length}'),
            Text('autoReconnect: ${config.autoReconnect}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}

class _BleConfigDialog extends StatefulWidget {
  const _BleConfigDialog({
    required this.initialJson,
    required this.onSaveConfig,
  });

  final String initialJson;
  final Future<void> Function(String rawJson) onSaveConfig;

  @override
  State<_BleConfigDialog> createState() => _BleConfigDialogState();
}

class _BleConfigDialogState extends State<_BleConfigDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialJson);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('BLE config JSON'),
      content: SizedBox(
        width: 560,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 16,
          minLines: 8,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Paste BleConfig JSON or JSON array',
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await widget.onSaveConfig(_controller.text);
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            } catch (error) {
              messenger.showSnackBar(
                SnackBar(content: Text('Config invalid: $error')),
              );
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Device detail content used by the home page after a G2 device is selected.
class _DeviceDetailContent extends StatelessWidget {
  const _DeviceDetailContent({
    required this.device,
    required this.logs,
    required this.logVersion,
    required this.legState,
    required this.primaryActionLabel,
    required this.primaryActionIcon,
    required this.primaryActionEnabled,
    required this.onPrimaryAction,
    required this.onRemove,
  });

  final BleMatchDevice device;
  final List<String> logs;
  final ValueNotifier<int> logVersion;
  final BleConnectState Function(String uuid) legState;
  final String Function() primaryActionLabel;
  final IconData Function() primaryActionIcon;
  final bool Function() primaryActionEnabled;
  final Future<void> Function() onPrimaryAction;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context) {
    final legs = _sortedG2Legs(device.devices);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<int>(
            valueListenable: logVersion,
            builder: (context, _, __) {
              // Native auto reconnect updates per-leg connectStatus even when
              // the foreground connect flag is false, so the summary card must
              // rebuild from the same notifier used by logs and action buttons.
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SN: ${device.sn}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      for (final entry in legs.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            _formatG2Leg(
                              entry.$2,
                              entry.$1,
                              state: legState(entry.$2.uuid),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: logVersion,
            builder: (context, _, __) {
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                reverse: true,
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      logs[index],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<int>(
            valueListenable: logVersion,
            builder: (context, _, __) {
              final enabled = primaryActionEnabled();
              return Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: enabled ? onPrimaryAction : null,
                      icon: enabled
                          ? Icon(primaryActionIcon())
                          : const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                      label: Text(primaryActionLabel()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: enabled ? onRemove : null,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

List<BleDevice> _sortedG2Legs(List<BleDevice> devices) {
  return devices.toList()
    ..sort((left, right) {
      // Always render left before right so scan rows, logs, and persisted
      // restore views use the same mental model.
      final leftOrder = _g2LegOrder(left.name);
      final rightOrder = _g2LegOrder(right.name);
      if (leftOrder != rightOrder) {
        return leftOrder.compareTo(rightOrder);
      }
      return left.name.compareTo(right.name);
    });
}

String _formatG2Leg(BleDevice device, int index, {BleConnectState? state}) {
  final name = device.name.isEmpty ? 'Unknown' : device.name;
  final stateText = state == null ? '' : '  |  State: ${state.name}';
  return '${_g2LegLabel(device, index)}: $name  |  MAC: ${_displayMac(device)}$stateText';
}

/// Returns the user-facing leg label, falling back to a stable ordinal.
String _g2LegLabel(BleDevice device, int index) {
  final side = _g2LegSide(device.name);
  if (side == 'L') {
    return 'Left leg';
  }
  if (side == 'R') {
    return 'Right leg';
  }
  return 'Leg ${index + 1}';
}

/// Returns sort order for left/right/unknown leg names.
int _g2LegOrder(String name) {
  final side = _g2LegSide(name);
  if (side == 'L') {
    return 0;
  }
  if (side == 'R') {
    return 1;
  }
  return 2;
}

/// Extracts leg side from common G2 advertisement name formats.
String? _g2LegSide(String name) {
  final upperName = name.toUpperCase();
  if (RegExp(r'(^|[_\-\s])L([_\-\s]|$)').hasMatch(upperName)) {
    return 'L';
  }
  if (RegExp(r'(^|[_\-\s])R([_\-\s]|$)').hasMatch(upperName)) {
    return 'R';
  }
  return null;
}

/// Displays MAC when available, otherwise the platform UUID as identity backup.
String _displayMac(BleDevice device) {
  return device.mac.isEmpty ? device.uuid : device.mac;
}
