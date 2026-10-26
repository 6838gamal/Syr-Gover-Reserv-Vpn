import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'import_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VpnConfig> _configs = [];
  VpnConfig? _selected;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final ctrl = context.read<VpnController>();
    final list = await ctrl.store.loadAll();
    if (!mounted) return;
    setState(() {
      _configs = list;
      _selected = list.isNotEmpty ? list.first : null;
    });
  }

  Future<void> _toggle() async {
    final ctrl = context.read<VpnController>();
    final st = ctrl.state.status;
    if (st == VpnStatus.connected) {
      await ctrl.disconnect();
    } else if (st == VpnStatus.disconnected && _selected != null) {
      await ctrl.connect(_selected!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<VpnController>();
    final state = ctrl.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My VPN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'استيراد',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ImportScreen()),
              );
              await _loadConfigs();
            },
          ),
          IconButton(
            icon: Icon(
              ctrl.autoReconnectEnabled
                  ? Icons.sync
                  : Icons.sync_disabled,
            ),
            tooltip: ctrl.autoReconnectEnabled
                ? 'إعادة الاتصال التلقائي: مفعّل'
                : 'إعادة الاتصال التلقائي: متوقف',
            onPressed: () {
              ctrl.autoReconnectEnabled = !ctrl.autoReconnectEnabled;
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(state: state),
            const SizedBox(height: 24),
            DropdownButtonFormField<VpnConfig>(
              value: _selected,
              decoration: const InputDecoration(
                labelText: 'اختر الإعدادات',
                border: OutlineInputBorder(),
              ),
              items: _configs
                  .map((c) =>
                      DropdownMenuItem(value: c, child: Text(c.name)))
                  .toList(),
              onChanged: (c) => setState(() => _selected = c),
            ),
            const SizedBox(height: 16),
            if (_selected != null) ...[
              Text('Endpoint: ${_selected!.endpoint}'),
              Text('Address: ${_selected!.address}'),
              Text('DNS: ${_selected!.dns}'),
              Text('Keepalive: ${_selected!.persistentKeepalive}s'),
              Text('MTU: ${_selected!.mtu}'),
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: (state.status == VpnStatus.connecting ||
                      state.status == VpnStatus.disconnecting)
                  ? null
                  : _toggle,
              icon: Icon(
                state.status == VpnStatus.connected
                    ? Icons.stop
                    : Icons.play_arrow,
              ),
              label: Text(
                state.status == VpnStatus.connected ? 'قطع' : 'اتصال',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final VpnState state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state.status) {
      VpnStatus.connected => (Colors.green, 'متصل'),
      VpnStatus.connecting => (Colors.orange, 'جارٍ الاتصال...'),
      VpnStatus.disconnecting => (Colors.orange, 'جارٍ القطع...'),
      VpnStatus.error => (Colors.red, 'خطأ'),
      _ => (Colors.grey, 'غير متصل'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.shield, size: 64, color: color),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 22,
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
