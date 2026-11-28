import 'dart:async';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

/// جسر آمن للمنصات غير المدعومة (iOS حالياً).
/// كل الدوال تعيد false بدلاً من crash، ولا تنفذ أي عملية نظام.
class VpnBridgeStub implements VpnBridge {
  VpnState _state = const VpnState(status: VpnStatus.disconnected);
  final _controller = StreamController<VpnState>.broadcast();

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

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool> requestNotificationPermission() async => false;

  @override
  Future<void> connect(VpnConfig config) async {
    throw VpnException(
      'VPN not supported on this platform',
      code: 'UNSUPPORTED',
    );
  }

  @override
  Future<void> disconnect() async {}

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  @override
  Future<void> refreshState() async {}

  @override
  Future<bool> isConnected() async => false;

  @override
  Future<LinkHealth> probeHealth() async => LinkHealth.down;

  // Autostart / Always-on / Kill Switch — الافتراضيات كافية
  // (getAutostart → false، setAutostart → no-op، إلخ)

  void _emit(VpnState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }
}
