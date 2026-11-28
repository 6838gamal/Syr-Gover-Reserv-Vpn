import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

/// جسر آمن للمنصات غير المدعومة (iOS حالياً).
/// كل الدوال تعيد false بدلاً من crash، ولا تنفذ أي عملية نظام.
class VpnBridgeStub implements VpnBridge {
  VpnState _state = VpnState.initial();
  final _controller = StreamController<VpnState>.broadcast();

  @override
  Future<void> init() async {
    _emit(_state.copyWith(
      status: VpnStatus.disconnected,
      errorMessage: 'VPN not supported on this platform',
    ));
  }

  @override
  void dispose() {
    _controller.close();
  }

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool> requestNotificationPermission() async => false;

  @override
  Future<void> connect(VpnConfig config) async {
    throw VpnException('VPN not supported on this platform',
        code: 'UNSUPPORTED');
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

  // كل الإضافات الافتراضية كافية (no-op / false)

  void _emit(VpnState s) {
    _state = s;
    _controller.add(s);
  }
}
