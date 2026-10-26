import 'dart:async';
import 'dart:io' show Platform, SocketException, InternetAddress;

import 'package:flutter/foundation.dart' show kIsWeb, ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'models/vpn_config.dart';
import 'models/vpn_state.dart';
import 'services/config_store.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_android.dart';
import 'services/vpn_bridge_desktop.dart';

/// يتحكم بدورة حياة الـ bridge + الحالة + إعادة الاتصال التلقائي
class VpnController extends ChangeNotifier {
  final VpnBridge bridge;
  final ConfigStore store = ConfigStore();

  StreamSubscription<VpnState>? _stateSub;
  Timer? _networkWatchdog;
  bool _wasConnectedBeforeOutage = false;
  bool _autoReconnectEnabled = true;

  VpnController(this.bridge) {
    _stateSub = bridge.stateStream.listen(_onStateChanged);
    _startNetworkWatchdog();
  }

  VpnState get state => bridge.currentState;

  bool get autoReconnectEnabled => _autoReconnectEnabled;
  set autoReconnectEnabled(bool v) {
    _autoReconnectEnabled = v;
    notifyListeners();
  }

  void _onStateChanged(VpnState s) {
    if (s.status == VpnStatus.connected) {
      _wasConnectedBeforeOutage = true;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // مراقب الشبكة: كل 10 ثوانٍ نتحقق إن كان الإنترنت عاد بعد انقطاع
  // ---------------------------------------------------------------------------
  void _startNetworkWatchdog() {
    _networkWatchdog?.cancel();
    _networkWatchdog =
        Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_autoReconnectEnabled) return;
      if (state.status != VpnStatus.connected) return;
      if (!_wasConnectedBeforeOutage) return;

      final online = await _hasInternet();
      if (!online) {
        // الإنترنت انقطع — انتظر الإعادة
        return;
      }

      // الإنترنت عاد — اطلب "kick" من الجسر (لا يغيّر أي إعدادات)
      try {
        await bridge.onNetworkChanged();
      } catch (_) {
        // لا نُفشل الدورة — فقط نحاول في المرة القادمة
      }
    });
  }

  Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('1.1.1.1')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // أوامر عالية المستوى للواجهة
  // ---------------------------------------------------------------------------
  Future<bool> connect(VpnConfig config) async {
    final ok = await bridge.requestPermission();
    if (!ok) return false;
    await bridge.connect(config);
    return true;
  }

  Future<void> disconnect() async {
    _wasConnectedBeforeOutage = false;
    await bridge.disconnect();
  }

  @override
  void dispose() {
    _networkWatchdog?.cancel();
    _stateSub?.cancel();
    bridge.dispose();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// نقطة الدخول
// -----------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- معاينة الويب فقط ----------
  if (kIsWeb) {
    runApp(
      ChangeNotifierProvider(
        create: (_) => _FakeVpnController(),
        child: const MyVpnApp(),
      ),
    );
    return;
  }

  // ---------- اختيار الجسر حسب المنصة ----------
  final VpnBridge bridge;
  if (Platform.isAndroid || Platform.isIOS) {
    bridge = VpnBridgeAndroid();
  } else {
    // Linux / Windows / macOS
    bridge = VpnBridgeDesktop();
  }

  try {
    await bridge.init();
  } catch (e, st) {
    // بدلاً من انهيار صامت، اعرض شاشة خطأ
    runApp(_BootstrapErrorApp(message: e.toString(), stack: st.toString()));
    return;
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<VpnBridge>.value(value: bridge),
        ChangeNotifierProvider(create: (_) => VpnController(bridge)),
      ],
      child: const MyVpnApp(),
    ),
  );
}

// -----------------------------------------------------------------------------
// Stub لواجهة الويب (لا يعمل VPN في المتصفح)
// -----------------------------------------------------------------------------
class _FakeVpnController extends ChangeNotifier {
  VpnState get state => const VpnState(
        status: VpnStatus.disconnected,
        errorMessage: 'VPN غير مدعوم في المتصفح — هذه معاينة للواجهة فقط',
      );
  bool autoReconnectEnabled = true;
  final ConfigStore store = ConfigStore();

  Future<bool> connect(VpnConfig _) async => false;
  Future<void> disconnect() async {}
}

// -----------------------------------------------------------------------------
// شاشة خطأ التهيئة (لو فشل bridge.init)
// -----------------------------------------------------------------------------
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
