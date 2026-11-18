import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

/// الواجهة المجردة لـ VPN Bridge.
///
/// تُنفَّذ بواسطة:
/// - [VpnBridgeAndroid] (Android — عبر MethodChannel + EventChannel)
/// - [VpnBridgeDesktop] (Windows/Linux/macOS — عبر Process)
///
/// الدوال "الاختيارية" (مثل سجل الأخطاء وإعدادات البطارية) لها
/// تنفيذ افتراضي آمن هنا، وتُتجاوز (override) في Android فقط.
abstract class VpnBridge {
  // ------------------------------------------------------------------
  // دورة الحياة الأساسية
  // ------------------------------------------------------------------

  Future<void> init();

  /// يطلب صلاحية VPN. يعيد true إذا مُنحت.
  Future<bool> requestPermission();

  /// يطلب صلاحية الإشعارات (Android 13+). التنفيذ الافتراضي: true.
  Future<bool> requestNotificationPermission() async => true;

  Future<void> connect(VpnConfig config);
  Future<void> disconnect();

  /// إعادة الاتصال (kick). التنفيذ الافتراضي: لا شيء.
  Future<void> kick() async {}

  Future<bool> isConnected();

  /// تحديث الحالة من المصدر الأصلي. التنفيذ الافتراضي: لا شيء.
  Future<void> refreshState() async {}

  Stream<VpnState> get stateStream;
  VpnState get currentState;

  Future<void> onNetworkChanged();

  void dispose();

  // ------------------------------------------------------------------
  // سجل أخطاء الإشعارات (Android فقط — stubs هنا)
  // ------------------------------------------------------------------

  /// قراءة سجل أخطاء الإشعارات (نص خام).
  Future<String> getNotificationErrorLog() async => '';

  /// مسح سجل أخطاء الإشعارات.
  Future<bool> clearNotificationErrorLog() async => false;

  // ------------------------------------------------------------------
  // تحسين البطارية (Android فقط — stubs هنا)
  // ------------------------------------------------------------------

  /// هل التطبيق مستثنى حالياً من تحسين البطارية؟
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  // ------------------------------------------------------------------
  // إعدادات التطبيق (Android فقط — stubs هنا)
  // ------------------------------------------------------------------

  /// فتح شاشة إعدادات التطبيق في النظام.
  Future<bool> openAppSettings() async => false;

  // ------------------------------------------------------------------
  // إدارة الإعداد المحفوظ
  // ------------------------------------------------------------------

  /// آخر إعداد محفوظ (Android: من SharedPreferences، Desktop: من الذاكرة).
  Future<Map<String, dynamic>?> getLastConfig() async => null;

  /// مسح الإعداد المحفوظ.
  Future<void> clearLastConfig() async {}
}
