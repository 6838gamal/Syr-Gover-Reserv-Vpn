import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'import_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VpnConfig> _configs = [];
  VpnConfig? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadConfigs());
  }

  Future<void> _loadConfigs() async {
    final ctrl = context.read<VpnController>();
    final list = await ctrl.store.loadAll();
    if (!mounted) return;
    setState(() {
      _configs = list;
      // حافظ على الاختيار السابق إن وُجد
      if (_selected != null) {
        final idx = list.indexWhere((c) => c.name == _selected!.name);
        _selected = idx >= 0 ? list[idx] : (list.isNotEmpty ? list.first : null);
      } else {
        _selected = list.isNotEmpty ? list.first : null;
      }
      _loading = false;
    });
  }

  Future<void> _toggle() async {
    final ctrl = context.read<VpnController>();
    final st = ctrl.state.status;

    if (st == VpnStatus.connected) {
      await ctrl.disconnect();
      return;
    }

    if (st == VpnStatus.disconnected && _selected != null) {
      final ok = await ctrl.connect(_selected!);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذّر الحصول على صلاحية VPN'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _openImport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ImportScreen()),
    );
    await _loadConfigs();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<VpnController>();
    final state = ctrl.state;
    final busy = state.status == VpnStatus.connecting ||
        state.status == VpnStatus.disconnecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My VPN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'استيراد إعدادات',
            onPressed: _openImport,
          ),
          IconButton(
            icon: Icon(
              ctrl.autoReconnectEnabled ? Icons.sync : Icons.sync_disabled,
            ),
            tooltip: ctrl.autoReconnectEnabled
                ? 'إعادة الاتصال التلقائي: مفعّل'
                : 'إعادة الاتصال التلقائي: متوقف',
            onPressed: () {
              ctrl.autoReconnectEnabled = !ctrl.autoReconnectEnabled;
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'إعدادات',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(state: state),
                  const SizedBox(height: 20),
                  _buildConfigPicker(),
                  const SizedBox(height: 16),
                  if (_selected != null) _buildDetails(_selected!),
                  const Spacer(),
                  _buildMainButton(state, busy),
                ],
              ),
            ),
    );
  }

  Widget _buildConfigPicker() {
    if (_configs.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Icon(Icons.info_outline, size: 40),
              const SizedBox(height: 8),
              const Text('لا توجد إعدادات بعد'),
              const SizedBox(height: 4),
              const Text(
                'اضغط + لاستيراد ملف .conf',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openImport,
                icon: const Icon(Icons.upload_file),
                label: const Text('استيراد الآن'),
              ),
            ],
          ),
        ),
      );
    }

    return DropdownButtonFormField<VpnConfig>(
      value: _selected,
      decoration: const InputDecoration(
        labelText: 'اختر الإعدادات',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.list),
      ),
      items: _configs
          .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
          .toList(),
      onChanged: (c) => setState(() => _selected = c),
    );
  }

  Widget _buildDetails(VpnConfig c) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow(Icons.dns, 'Endpoint', c.endpoint),
            _detailRow(Icons.lan, 'Address', c.address),
            _detailRow(Icons.public, 'DNS', c.dns),
            _detailRow(Icons.speed, 'MTU', '${c.mtu}'),
            _detailRow(Icons.timer, 'Keepalive',
                '${c.persistentKeepalive}s'),
            _detailRow(Icons.vpn_key, 'Allowed IPs', c.allowedIps),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white54),
          const SizedBox(width: 8),
          Text('$label: ',
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainButton(VpnState state, bool busy) {
    final connected = state.status == VpnStatus.connected;
    final noConfig = _selected == null;

    return FilledButton.icon(
      onPressed: (busy || (noConfig && !connected)) ? null : _toggle,
      icon: Icon(connected ? Icons.stop : Icons.play_arrow),
      label: Text(
        connected ? 'قطع الاتصال' : 'اتصال',
        style: const TextStyle(fontSize: 16),
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
        backgroundColor: connected ? Colors.redAccent : null,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// بطاقة الحالة
// -----------------------------------------------------------------------------
class _StatusCard extends StatelessWidget {
  final VpnState state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (state.status) {
      VpnStatus.connected => (Colors.green, 'متصل', Icons.shield),
      VpnStatus.connecting => (Colors.orange, 'جارٍ الاتصال...', Icons.hourglass_top),
      VpnStatus.disconnecting => (Colors.orange, 'جارٍ القطع...', Icons.hourglass_bottom),
      VpnStatus.error => (Colors.red, 'خطأ', Icons.error),
      VpnStatus.disconnected => (Colors.grey, 'غير متصل', Icons.shield_outlined),
    };

    return Card(
      color: color.withOpacity(0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, size: 64, color: color),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 22,
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (state.activeConfigName != null &&
                state.status == VpnStatus.connected) ...[
              const SizedBox(height: 4),
              Text(
                state.activeConfigName!,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
