import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

abstract class VpnBridge {
  /// يهيّئ الجسر (يُستدعى في main قبل runApp)
  Future<void> init();

  /// يطلب صلاحية VPN من المستخدم (Android) أو لا يفعل شيئاً (desktop)
  Future<bool> requestPermission();

  Future<void> connect(VpnConfig config);
  Future<void> disconnect();

  /// تدفق حالة الاتصال
  Stream<VpnState> get stateStream;
  VpnState get currentState;

  /// يُستدعى عند تغيّر الشبكة (لإعادة الاتصال تلقائياً)
  Future<void> onNetworkChanged();

  void dispose();
}

/// Factory يختار التنفيذ المناسب حسب المنصة
VpnBridge createVpnBridge() {
  throw UnimplementedError('يُنفذ في main حسب المنصة');
}
