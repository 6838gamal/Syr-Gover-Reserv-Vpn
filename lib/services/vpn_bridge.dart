import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

abstract class VpnBridge {
  Future<void> init();
  Future<bool> requestPermission();
  Future<bool> requestNotificationPermission() async => true;
  Future<void> connect(VpnConfig config);
  Future<void> disconnect();
  Future<void> kick() async {}
  Future<bool> isConnected();
  Future<void> refreshState() async {}
  Stream<VpnState> get stateStream;
  VpnState get currentState;
  Future<void> onNetworkChanged();
  void dispose();
}
