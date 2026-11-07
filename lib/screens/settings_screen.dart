import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/vpn_bridge_android.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autostart = false;
  bool _isAndroid = false;

  @override
  void initState() {
    super.initState();
    _isAndroid = !kIsWeb && Platform.isAndroid;
    if (_isAndroid) _loadAutostart();
  }

  Future<void> _loadAutostart() async {
    final ctrl = context.read<VpnController>();
    if (ctrl.bridge is VpnBridgeAndroid) {
      final v = await (ctrl.bridge as VpnBridgeAndroid).isAutostartEnabled();
      if (mounted) setState(() => _autostart = v);
    }
  }

  Future<void> _toggleAutostart(bool v) async {
    final ctrl = context.read<VpnController>();
    if (ctrl.bridge is VpnBridgeAndroid) {
      await (ctrl.bridge as VpnBridgeAndroid).setAutostart(v);
      setState(() => _autostart = v);
    }
  }

  Future<void> _openAlwaysOn() async {
    final ctrl = context.read<VpnController>();
    if (ctrl.bridge is VpnBridgeAndroid) {
      await (ctrl.bridge as VpnBridgeAndroid).openAlwaysOnSettings();
    }
  }

  Future<void> _openBattery() async {
    final ctrl = context.read<VpnController>();
    if (ctrl.bridge is VpnBridgeAndroid) {
      await (ctrl.bridge as VpnBridgeAndroid)
          .requestBatteryOptimizationExemption();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<VpnController>();

    return Scaffold(
      appBar: AppBar(title: const Text('إعدادات')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('إعادة الاتصال التلقائي'),
            subtitle: const Text('يحاول الاتصال بعد عودة الإنترنت'),
            value: ctrl.autoReconnectEnabled,
            onChanged: (v) => ctrl.autoReconnectEnabled = v,
          ),
          if (_isAndroid) ...[
            const Divider(),
            SwitchListTile(
              title: const Text('التشغيل عند الإقلاع'),
              subtitle: const Text(
                  'يفعّل VPN تلقائياً عند إعادة تشغيل الجوال (يتطلب Always-on VPN)'),
              value: _autostart,
              onChanged: _toggleAutostart,
            ),
            ListTile(
              leading: const Icon(Icons.security),
              title: const Text('Always-on VPN'),
              subtitle:
                  const Text('افتح إعدادات النظام وفعّل Always-on VPN'),
              trailing: const Icon(Icons.open_in_new),
              onTap: _openAlwaysOn,
            ),
            ListTile(
              leading: const Icon(Icons.battery_saver),
              title: const Text('إعفاء من تحسين البطارية'),
              subtitle: const Text(
                  'ضروري على Xiaomi/Huawei/Samsung ليبقى VPN شغالاً'),
              trailing: const Icon(Icons.open_in_new),
              onTap: _openBattery,
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('خطوات التشغيل الدائم على Android:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
                      Text('1. اتصل بـ VPN مرة واحدة (لمنح الصلاحية)'),
                      Text('2. افتح إعدادات Always-on VPN من الزر أعلاه'),
                      Text('3. فعّل Always-on VPN لتطبيق My VPN'),
                      Text('4. فعّل "Block connections without VPN"'),
                      Text('5. فعّل إعفاء البطارية'),
                      Text('6. أعد تشغيل الجوال للتأكد'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// kIsWeb يأتي من flutter/foundation
// (تم استيراده تلقائياً عبر material)
