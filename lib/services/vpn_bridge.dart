import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

class VpnException implements Exception {
  final String message;
  final String? code;
  VpnException(this.message, {this.code});

  @override
  String toString() => 'VpnException($code): $message';
}

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

  /// ✅ [networkKey] اختياري — يمنع kick المتكرر
  Future<void> onNetworkChanged({String? networkKey}) async {}

  void dispose();

  Future<String> getNotificationErrorLog() async => '';
  Future<bool> clearNotificationErrorLog() async => false;
  Future<bool> isIgnoringBatteryOptimizations() async => false;
  Future<bool> openAppSettings() async => false;
  Future<Map<String, dynamic>?> getLastConfig() async => null;
  Future<void> clearLastConfig() async {}
}
