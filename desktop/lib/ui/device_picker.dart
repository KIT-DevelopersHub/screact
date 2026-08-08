import 'package:flutter/material.dart';

import '../net/discovery.dart';

/// AirDrop 風のデバイス選択UI。発見された Android をカードで並べ、
/// タップで1台を選ぶ（2台以上検出時に表示する）。
class DevicePickerGrid extends StatelessWidget {
  final List<DiscoveredDevice> devices;
  final ValueChanged<DiscoveredDevice> onSelect;
  const DevicePickerGrid({
    super.key,
    required this.devices,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 18,
      runSpacing: 18,
      alignment: WrapAlignment.center,
      children: [
        for (final d in devices) _DeviceCard(device: d, onTap: () => onSelect(d)),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;
  const _DeviceCard({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 148,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [cs.primary, const Color(0xFF4C8DD8)],
                  ),
                ),
                child: const Icon(Icons.smartphone, color: Colors.white, size: 30),
              ),
              const SizedBox(height: 12),
              Text(
                device.deviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                device.address.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
