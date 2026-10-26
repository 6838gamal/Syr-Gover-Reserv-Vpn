import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

/// العقد الموحد الذي تنفذه كل منصة
abstract class VpnBridge {
  /// تهيئة الجسر (يُستدعى في main قبل runApp)
  Future<void> init();

  /// طلب صلاحية VPN (Android) أو التحقق من توفر الأدوات (Desktop)
  Future<bool> requestPermission();

  /// الاتصال بإعدادات معيّنة
  Future<void> connect(VpnConfig config);

  /// قطع الاتصال
  Future<void> disconnect();

  /// تدفق حالة الاتصال
  Stream<VpnState> get stateStream;

  /// الحالة الحالية
  VpnState get currentState;

  /// يُستدعى عند تغيّر الشبكة (لإعادة الاتصال تلقائياً)
  Future<void> onNetworkChanged();

  /// تنظيف الموارد
  void dispose();
}
