import 'vpn_bridge.dart';

// على الويب: stub
// على أي منصة فيها dart:io: التنفيذ الحقيقي
import 'vpn_bridge_web.dart'
    if (dart.library.io) 'vpn_bridge_platform.dart' as impl;

VpnBridge createVpnBridge() => impl.createVpnBridge();
