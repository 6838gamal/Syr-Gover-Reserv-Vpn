import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_android.dart';
import 'services/vpn_bridge_desktop.dart';
import 'services/config_store.dart';

class VpnController extends ChangeNotifier {
  final VpnBridge bridge;
  final ConfigStore store = ConfigStore();
  VpnController(this.bridge) {
    bridge.stateStream.listen((_) => notifyListeners());
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final VpnBridge bridge;
  if (Platform.isAndroid || Platform.isIOS) {
    bridge = VpnBridgeAndroid();
  } else {
    bridge = VpnBridgeDesktop();
  }
  await bridge.init();

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
