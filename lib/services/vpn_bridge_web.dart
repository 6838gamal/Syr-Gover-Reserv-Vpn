import 'dart:async';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

class VpnBridgeWeb implements VpnBridge {
  final _controller = StreamController<VpnState>.broadcast();
  VpnState _state = const VpnState(
    status: VpnStatus.disconnected,
    errorMessage: 'VPN غير مدعوم في المتصفح — هذه معاينة للواجهة فقط',
  );

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> connect(VpnConfig config) async {
    _state = const VpnState(
      status: VpnStatus.error,
      errorMessage: 'VPN غير مدعوم في المتصفح',
    );
    _controller.add(_state);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> onNetworkChanged() async {}

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  @override
  void dispose() => _controller.close();
}

VpnBridge createVpnBridge() => VpnBridgeWeb();
