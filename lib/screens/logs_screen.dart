import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';   // ← VpnController, VpnLog, LogLevel

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
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'مسح السجل',
            onPressed: ctrl.clearLogs,
          ),
        ],
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
                    style: const TextStyle(fontSize: 11, color: Colors.white38),
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
