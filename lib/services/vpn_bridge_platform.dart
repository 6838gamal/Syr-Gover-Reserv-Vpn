import 'dart:io' show Platform;

import 'vpn_bridge.dart';
import 'vpn_bridge_android.dart';
import 'vpn_bridge_desktop.dart';

VpnBridge createVpnBridge() {
  if (Platform.isAndroid || Platform.isIOS) {
    return VpnBridgeAndroid();
  }
  return VpnBridgeDesktop();
}
