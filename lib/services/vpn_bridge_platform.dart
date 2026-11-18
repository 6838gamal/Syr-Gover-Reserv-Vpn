import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'vpn_bridge.dart';
import 'vpn_bridge_android.dart';
import 'vpn_bridge_desktop.dart';

/// ينشئ الـ VpnBridge المناسب حسب المنصة.
///
/// - Android: VpnBridgeAndroid (MethodChannel + EventChannel)
/// - iOS: VpnBridgeDesktop (غير مدعوم — يعيد false بأمان)
/// - Desktop (Windows/Linux/macOS): VpnBridgeDesktop
/// - Web: VpnBridgeDesktop (غير مدعوم — يعيد false بأمان)
VpnBridge createVpnBridge() {
  // الويب لا يدعم dart:io
  if (kIsWeb) {
    return VpnBridgeDesktop();
  }

  if (Platform.isAndroid) {
    return VpnBridgeAndroid();
  }

  // iOS غير مدعوم حالياً — نستخدم Desktop كـ stub آمن
  // (يعيد false بدلاً من crash)
  return VpnBridgeDesktop();
}
