import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

/// العقد الموحد الذي تنفذه كل منصة
abstract class VpnBridge {
  /// تهيئة الجسر (يُستدعى في main قبل runApp)
  Future<void> init();

  /// طلب صلاحية VPN (Android) أو التحقق من توفر الأدوات (Desktop)
  Future<bool> requestPermission();

  /// طلب صلاحية الإشعارات (Android 13+).
  /// الافتراضي: true (لأن Desktop/iOS لا يحتاجانها بهذا الشكل).
  Future<bool> requestNotificationPermission() async => true;

  /// الاتصال بإعدادات معيّنة
  Future<void> connect(VpnConfig config);

  /// قطع الاتصال
  Future<void> disconnect();

  /// إعادة الاتصال دون المرور بدورة قطع كاملة (يُستخدم للـ watchdog).
  /// الافتراضي: قطع + اتصال.
  Future<void> kick() async {
    await disconnect();
    // لا نعرف الإعدادات الأخيرة هنا — الطبقات المنفذة تُعيد override
  }

  /// هل الخدمة متصلة فعلياً الآن؟ (لا يعتمد على الحالة المخزنة فقط)
  Future<bool> isConnected();

  /// تدفق حالة الاتصال
  Stream<VpnState> get stateStream;

  /// الحالة الحالية
  VpnState get currentState;

  /// يُستدعى عند تغيّر الشبكة (لإعادة الاتصال تلقائياً)
  Future<void> onNetworkChanged();

  /// تنظيف الموارد
  void dispose();
}
