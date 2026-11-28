import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/vpn_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autostart = false;
  bool _isAndroid = false;
  bool _loadingAutostart = false;

  @override
  void initState() {
    super.initState();
    _isAndroid = !kIsWeb && Platform.isAndroid;
    if (_isAndroid) {
      // context.read في initState غير آمن — نؤجل للـ post-frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAutostart());
    }
  }

  Future<void> _loadAutostart() async {
    if (!mounted) return;
    setState(() => _loadingAutostart = true);
    try {
      final ctrl = context.read<VpnController>();
      final v = await ctrl.bridge.getAutostart();
      if (mounted) setState(() => _autostart = v);
    } catch (_) {
      // تجاهل — سيبقى false
    } finally {
      if (mounted) setState(() => _loadingAutostart = false);
    }
  }

  Future<void> _toggleAutostart(bool v) async {
    final ctrl = context.read<VpnController>();
    // تفاؤلي: نحدّث الواجهة فوراً
    setState(() => _autostart = v);
    try {
      await ctrl.bridge.setAutostart(v);
    } catch (e) {
      if (!mounted) return;
      // رجوع عند الفشل
      setState(() => _autostart = !v);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل تغيير التشغيل التلقائي: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _openAlwaysOn() async {
    final ctrl = context.read<VpnController>();
    try {
      await ctrl.bridge.openAlwaysOnSettings();
    } catch (_) {}
  }

  Future<void> _openBattery() async {
    final ctrl = context.read<VpnController>();
    try {
      await ctrl.bridge.requestBatteryOptimizationExemption();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<VpnController>();

    return Scaffold(
      appBar: AppBar(title: const Text('إعدادات')),
      body: ListView(
        children: [
          // ══════════════════════════════════════════════════════
          // إعدادات عامة (كل المنصات)
          // ══════════════════════════════════════════════════════
          SwitchListTile(
            title: const Text('إعادة الاتصال التلقائي'),
            subtitle: const Text('يحاول الاتصال بعد عودة الإنترنت'),
            value: ctrl.autoReconnectEnabled,
            onChanged: (v) => ctrl.autoReconnectEnabled = v,
          ),
          SwitchListTile(
            title: const Text('Kill Switch'),
            subtitle: const Text(
                'يمنع كل الترافيك عند سقوط النفق — حتى يتعافى'),
            value: ctrl.killSwitchEnabled,
            onChanged: (v) => ctrl.killSwitchEnabled = v,
          ),

          // ══════════════════════════════════════════════════════
          // إعدادات Android فقط
          // ══════════════════════════════════════════════════════
          if (_isAndroid) ...[
            const Divider(),
            SwitchListTile(
              title: const Text('التشغيل عند الإقلاع'),
              subtitle: const Text(
                  'يفعّل VPN تلقائياً عند إعادة تشغيل الجوال (يتطلب Always-on VPN)'),
              value: _autostart,
              onChanged: _loadingAutostart ? null : _toggleAutostart,
              secondary: _loadingAutostart
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
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

            // ── خطوات التشغيل الدائم ──────────────────────────
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

          // ══════════════════════════════════════════════════════
          // Kill Switch — حالة مباشرة (للتشخيص)
          // ══════════════════════════════════════════════════════
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: ListTile(
                leading: Icon(
                  ctrl.isNetworkUntrusted
                      ? Icons.wifi_off
                      : Icons.wifi,
                  color: ctrl.isNetworkUntrusted
                      ? Colors.orange
                      : Colors.green,
                ),
                title: Text(
                  ctrl.isNetworkUntrusted
                      ? 'الشبكة غير موثوقة'
                      : 'الشبكة سليمة',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'Link: ${ctrl.linkHealth.name}'
                  '${ctrl.isNetworkUntrusted ? " — التصفّح محجوب" : ""}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
