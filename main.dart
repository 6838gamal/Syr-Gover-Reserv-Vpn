import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_android.dart';
import 'services/vpn_bridge_desktop.dart';

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
    ChangeNotifierProvider(
      create: (_) => VpnController(bridge),
    ),
    // ملاحظة: runApp يستقبل widget واحد فقط. استخدم MultiProvider.
  );
}
