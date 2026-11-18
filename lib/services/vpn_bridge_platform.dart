import 'dart:io' show Platform;

import 'vpn_bridge.dart';
import 'vpn_bridge_android.dart';
import 'vpn_bridge_desktop.dart';

/// ينشئ الـ VpnBridge المناسب للمنصات التي تدعم dart:io
/// (Android / iOS / Windows / Linux / macOS).
///
/// ملاحظة: هذا الملف **لا يُستورد على الويب** بفضل conditional import
/// في `vpn_factory.dart`، لذا استخدام `dart:io` آمن هنا.
VpnBridge createVpnBridge() {
  if (Platform.isAndroid) {
    return VpnBridgeAndroid();
  }

  // iOS غير مدعوم حالياً — نستخدم Desktop كـ stub آمن
  // (كل الدوال تعيد false بدلاً من crash)
  return VpnBridgeDesktop();
}
