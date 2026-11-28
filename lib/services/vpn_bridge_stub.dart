import 'dart:async';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';
import '../models/link_health.dart';

/// جسر آمن للمنصات غير المدعومة (iOS حالياً).
/// كل الدوال تعيد false بدلاً من crash، ولا تنفذ أي عملية نظام.
class VpnBridgeStub implements VpnBridge {
  VpnState _state = const VpnState(status: VpnStatus.disconnected);
  final _controller = StreamController<VpnState>.broadcast();

  // ------------------------------------------------------------------
  // دورة الحياة
  // ------------------------------------------------------------------

  @override
  Future<void> init() async {
    _emit(const VpnState(
      status: VpnStatus.disconnected,
      errorMessage: 'VPN not supported on this platform',
    ));
  }

  @override
  void dispose() {
    if (!_controller.isClosed) _controller.close();
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
    throw VpnException(
      'VPN not supported on this platform',
      code: 'UNSUPPORTED',
    );
  }

  @override
  Future<void> disconnect() async {}

  // ------------------------------------------------------------------
  // الحالة
  // ------------------------------------------------------------------

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  @override
  Future<void> refreshState() async {}

  @override
  Future<bool> isConnected() async => false;

  // ------------------------------------------------------------------
  // صحة النفق
  // ------------------------------------------------------------------

  @override
  Future<LinkHealth> probeHealth() async => LinkHealth.down;

  @override
  Stream<LinkHealth> get healthStream => const Stream.empty();

  // ------------------------------------------------------------------
  // تغيّر الشبكة
  // ------------------------------------------------------------------

  @override
  Future<void> onNetworkChanged({String? networkKey}) async {}

  // ------------------------------------------------------------------
  // Kill Switch
  // ------------------------------------------------------------------

  @override
  Future<void> setKillSwitch(bool enabled) async {}

  @override
  Future<bool> isKillSwitchActive() async => false;

  // ------------------------------------------------------------------
  // Autostart / Always-on
  // ------------------------------------------------------------------

  @override
  Future<bool> getAutostart() async => false;

  @override
  Future<void> setAutostart(bool enabled) async {}

  @override
  Future<bool> openAlwaysOnSettings() async => false;

  @override
  Future<bool> requestBatteryOptimizationExemption() async => false;

  // ------------------------------------------------------------------
  // إضافات
  // ------------------------------------------------------------------

  @override
  Future<String> getNotificationErrorLog() async => '';

  @override
  Future<bool> clearNotificationErrorLog() async => false;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<Map<String, dynamic>?> getLastConfig() async => null;

  @override
  Future<void> clearLastConfig() async {}

  // ------------------------------------------------------------------
  // دوال مساعدة
  // ------------------------------------------------------------------

  void _emit(VpnState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }
}
