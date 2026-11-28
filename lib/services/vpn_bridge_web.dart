import 'dart:async';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

/// Web stub — VPN غير مدعوم على الويب.
///
/// كل الدوال تعيد قيماً آمنة (false / null / empty) بدون crash.
/// هذا الملف لا يُستورد على المنصات الأخرى بفضل conditional import
/// في `vpn_bridge_factory.dart`.
class VpnBridgeWeb implements VpnBridge {
  final _controller = StreamController<VpnState>.broadcast();

  VpnState _state = const VpnState(
    status: VpnStatus.disconnected,
    errorMessage: 'VPN غير مدعوم في المتصفح — هذه معاينة للواجهة فقط',
  );

  // ------------------------------------------------------------------
  // دورة الحياة
  // ------------------------------------------------------------------

  @override
  Future<void> init() async {
    _controller.add(_state);
  }

  @override
  Future<void> refreshState() async {
    _controller.add(_state);
  }

  // ------------------------------------------------------------------
  // الصلاحيات
  // ------------------------------------------------------------------

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool> requestNotificationPermission() async => false;

  // ------------------------------------------------------------------
  // الاتصال
  // ------------------------------------------------------------------

  @override
  Future<void> connect(VpnConfig config) async {
    _state = const VpnState(
      status: VpnStatus.error,
      errorMessage: 'VPN غير مدعوم في المتصفح',
    );
    _controller.add(_state);
  }

  @override
  Future<void> disconnect() async {
    _state = const VpnState(
      status: VpnStatus.disconnected,
      errorMessage: 'VPN غير مدعوم في المتصفح — هذه معاينة للواجهة فقط',
    );
    _controller.add(_state);
  }

  @override
  Future<bool> isConnected() async => false;

  // ------------------------------------------------------------------
  // الشبكة
  // ------------------------------------------------------------------

  @override
  Future<void> onNetworkChanged({String? networkKey}) async {
    // لا شيء على الويب
  }

  // ------------------------------------------------------------------
  // صحة النفق
  // ------------------------------------------------------------------

  @override
  Future<LinkHealth> probeHealth() async => LinkHealth.down;

  // healthStream: افتراضي Stream.empty() كافٍ

  // ------------------------------------------------------------------
  // Kill Switch
  // ------------------------------------------------------------------

  @override
  Future<void> setKillSwitch(bool enabled) async {
    // لا شيء على الويب
  }

  @override
  Future<bool> isKillSwitchActive() async => false;

  // ------------------------------------------------------------------
  // الحالة
  // ------------------------------------------------------------------

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  // ------------------------------------------------------------------
  // سجل أخطاء الإشعارات — stubs
  // ------------------------------------------------------------------

  @override
  Future<String> getNotificationErrorLog() async => '';

  @override
  Future<bool> clearNotificationErrorLog() async => false;

  // ------------------------------------------------------------------
  // تحسين البطارية — stubs
  // ------------------------------------------------------------------

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  // ------------------------------------------------------------------
  // إعدادات التطبيق — stubs
  // ------------------------------------------------------------------

  @override
  Future<bool> openAppSettings() async => false;

  // ------------------------------------------------------------------
  // إدارة الإعداد المحفوظ — stubs
  // ------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>?> getLastConfig() async => null;

  @override
  Future<void> clearLastConfig() async {}

  // ------------------------------------------------------------------
  // dispose
  // ------------------------------------------------------------------

  @override
  void dispose() {
    if (!_controller.isClosed) _controller.close();
  }
}

VpnBridge createVpnBridge() => VpnBridgeWeb();
