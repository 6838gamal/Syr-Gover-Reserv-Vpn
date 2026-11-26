import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

/// استثناء مخصص لأخطاء VPN — مشترك بين كل التنفيذات.
class VpnException implements Exception {
  final String message;
  final String? code;
  VpnException(this.message, {this.code});

  @override
  String toString() => 'VpnException($code): $message';
}

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

  /// تهيئة الجسر (تسجيل المستمعين + جلب الحالة الأولية).
  /// يجب استدعاؤها مرة واحدة عند بدء التطبيق.
  Future<void> init();

  /// يطلب صلاحية VPN. يعيد true إذا مُنحت.
  Future<bool> requestPermission();

  /// يطلب صلاحية الإشعارات (Android 13+).
  /// التنفيذ الافتراضي: true (المنصات الأخرى لا تحتاجها).
  Future<bool> requestNotificationPermission() async => true;

  /// يبدأ الاتصال.
  /// يرمي [VpnException] إذا فشل الاتصال أو نقصت صلاحية.
  Future<void> connect(VpnConfig config);

  /// يقطع الاتصال.
  Future<void> disconnect();

  /// إعادة الاتصال (kick). التنفيذ الافتراضي: لا شيء.
  Future<void> kick() async {}

  /// استعلام مباشر من الجانب الأصلي (أبطأ من قراءة [currentState]).
  Future<bool> isConnected();

  /// تحديث الحالة من المصدر الأصلي. التنفيذ الافتراضي: لا شيء.
  Future<void> refreshState() async {}

  /// بثّ تغييرات الحالة. متعدد المستمعين مسموح (broadcast).
  Stream<VpnState> get stateStream;

  /// الحالة الحالية (آخر قيمة معروفة — قراءة مجانية).
  VpnState get currentState;

  /// يُستدعى عند تغيّر نوع الشبكة (Wi-Fi ↔ بيانات، أو انقطاع).
  /// التنفيذ الافتراضي: لا شيء.
  Future<void> onNetworkChanged() async {}

  /// تحرير الموارد. يجب أن يكون آمناً للاستدعاء المتكرر (idempotent).
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
