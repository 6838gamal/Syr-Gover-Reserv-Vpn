import 'dart:io' show Platform;

import 'vpn_bridge.dart';
import 'vpn_bridge_android.dart';
import 'vpn_bridge_desktop.dart';
import 'vpn_bridge_stub.dart';

VpnBridge? _instance;

/// ينشئ الـ VpnBridge المناسب للمنصات التي تدعم dart:io.
/// singleton — نفس الكائن يُعاد في كل استدعاء (hot reload friendly).
VpnBridge createVpnBridge() {
  if (_instance != null) return _instance!;

  if (Platform.isAndroid) {
    _instance = VpnBridgeAndroid();
  } else if (Platform.isWindows) {
    _instance = VpnBridgeDesktop();
  } else {
    // iOS / Linux / macOS → stub آمن
    _instance = VpnBridgeStub();
  }
  return _instance!;
}
