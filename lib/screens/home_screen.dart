import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import '../services/vpn_bridge.dart';
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
    final store = context.read<VpnController>().store;
    final list = await store.loadAll();
    setState(() {
      _configs = list;
      _selected = list.isNotEmpty ? list.first : null;
    });
  }

  Future<void> _toggle(VpnBridge bridge) async {
    final st = bridge.currentState.status;
    if (st == VpnStatus.connected) {
      await bridge.disconnect();
    } else if (st == VpnStatus.disconnected && _selected != null) {
      final ok = await bridge.requestPermission();
      if (!ok) return;
      await bridge.connect(_selected!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridge = context.watch<VpnBridge>();
    final state = bridge.currentState;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My VPN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ImportScreen()),
              );
              _loadConfigs();
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
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: (state.status == VpnStatus.connecting ||
                      state.status == VpnStatus.disconnecting)
                  ? null
                  : () => _toggle(bridge),
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
            Text(label,
                style: TextStyle(
                    fontSize: 22,
                    color: color,
                    fontWeight: FontWeight.bold)),
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(state.errorMessage!,
                  style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }
}
