import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'models/vpn_config.dart';
import 'models/vpn_state.dart';
import 'services/config_store.dart';
import 'services/internet_check.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_factory.dart';

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
    if (s.status == VpnStatus.connected) _wasConnectedBeforeOutage = true;
    notifyListeners();
  }

  void _startNetworkWatchdog() {
    _networkWatchdog?.cancel();
    _networkWatchdog = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_autoReconnectEnabled) return;
      if (state.status != VpnStatus.connected) return;
      if (!_wasConnectedBeforeOutage) return;
      final online = await hasInternet();
      if (!online) return;
      try {
        await bridge.onNetworkChanged();
      } catch (_) {}
    });
  }

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final VpnBridge bridge = createVpnBridge();

  try {
    await bridge.init();
  } catch (e, st) {
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
              const Text('فشل بدء التشغيل',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
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
                        color: Colors.white70),
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
