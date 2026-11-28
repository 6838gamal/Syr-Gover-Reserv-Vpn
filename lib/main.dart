import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'controllers/vpn_controller.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_factory.dart';
import 'services/windows_elevation.dart';

// =============================================================================
// main()
// =============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Windows: elevation قبل أي شيء آخر ────────────────────────
  if (!kIsWeb && Platform.isWindows) {
    final admin = await WindowsElevation.isAdmin();
    if (!admin) {
      final elevated = await WindowsElevation.requestElevationAndExit();
      if (!elevated) {
        runApp(const _ElevationRequiredApp());
        return;
      }
      // إذا وصلنا هنا، العملية الأصلية انتهت (exit(0) في requestElevationAndExit)
      return;
    }
  }

  // ── إنشاء الجسر ──────────────────────────────────────────────
  final VpnBridge bridge = createVpnBridge();

  try {
    await bridge.init();
  } catch (e, st) {
    runApp(_BootstrapErrorApp(
      message: e.toString(),
      stack: st.toString(),
    ));
    return;
  }

  // ── تشغيل التطبيق ───────────────────────────────────────────
  runApp(
    MultiProvider(
      providers: [
        Provider<VpnBridge>.value(value: bridge),
        ChangeNotifierProvider<VpnController>(
          create: (_) => VpnController(bridge),
        ),
      ],
      child: const MyVpnApp(),
    ),
  );
}

// =============================================================================
// _ElevationRequiredApp
// =============================================================================

class _ElevationRequiredApp extends StatelessWidget {
  const _ElevationRequiredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF59E0B),
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings,
                    size: 72, color: Colors.amber),
                const SizedBox(height: 20),
                const Text(
                  'صلاحيات المسؤول مطلوبة',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'لتشغيل VPN على Windows، يحتاج التطبيق إلى صلاحيات مسؤول.\n\n'
                  'أغلق التطبيق ثم شغّله بزر الفأرة الأيمن → "Run as administrator"،\n'
                  'أو اضغط الزر أدناه لرفع الصلاحيات الآن.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, height: 1.6),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.lock_open),
                  label: const Text('رفع الصلاحيات والمحاولة مجدداً'),
                  onPressed: () async {
                    await WindowsElevation.requestElevationAndExit();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _BootstrapErrorApp
// =============================================================================

class _BootstrapErrorApp extends StatelessWidget {
  final String message;
  final String stack;
  const _BootstrapErrorApp({required this.message, required this.stack});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFEF4444),
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'فشل بدء التشغيل',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    stack,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
