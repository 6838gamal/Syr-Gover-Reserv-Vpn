import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/vpn_controller.dart';
import '../models/vpn_log.dart';
import '../services/vpn_bridge.dart' show LinkHealth;  // للوصول إلى LinkHealth

class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<VpnController>();
    final logs = ctrl.logs.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('سجل الاتصال'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'تحديث السجل',
            onPressed: () async {
              await ctrl.refreshState();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم تحديث السجل')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'مسح السجل',
            onPressed: ctrl.clearLogs,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Colors.white10,
            child: Row(
              children: [
                Icon(
                  switch (ctrl.linkHealth) {
                    LinkHealth.good => Icons.check_circle,
                    LinkHealth.suspect => Icons.warning_amber,
                    LinkHealth.down => Icons.cancel,
                    LinkHealth.unknown => Icons.help_outline,
                  },
                  size: 14,
                  color: switch (ctrl.linkHealth) {
                    LinkHealth.good => Colors.green,
                    LinkHealth.suspect => Colors.orange,
                    LinkHealth.down => Colors.red,
                    LinkHealth.unknown => Colors.grey,
                  },
                ),
                const SizedBox(width: 6),
                Text(
                  'Link: ${ctrl.linkHealth.name}'
                  '${ctrl.autoReconnectEnabled ? "" : " (auto-reconnect off)"}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
      body: logs.isEmpty
          ? const Center(child: Text('لا توجد سجلات بعد'))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: logs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = logs[i];
                final color = switch (e.level) {
                  LogLevel.error => Colors.redAccent,
                  LogLevel.warn => Colors.orangeAccent,
                  LogLevel.info => Colors.white70,
                };
                return ListTile(
                  dense: true,
                  leading: Text(
                    e.formattedTime,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white38),
                  ),
                  title: SelectableText(
                    e.message,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                );
              },
            ),
    );
  }
}
