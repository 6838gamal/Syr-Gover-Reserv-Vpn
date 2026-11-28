import '../models/vpn_config.dart';
import '../models/vpn_state.dart';

class VpnException implements Exception {
  final String message;
  final String? code;
  VpnException(this.message, {this.code});

  @override
  String toString() => 'VpnException($code): $message';
}

/// صحة الرابط من منظور النفق نفسه (وليس من منظور الإنترنت العام).
enum LinkHealth {
  /// لم نتحقق بعد (بداية التشغيل أو بعد الاتصال مباشرة).
  unknown,

  /// النفق يمرر ترافيك طبيعي.
  good,

  /// تذبذب/تأخير لكن النفق لم يسقط.
  suspect,

  /// النفق لا يمرر ترافيك — يجب اعتبار الشبكة غير موثوقة.
  down,
}

abstract class VpnBridge {
  // ── دورة الحياة ─────────────────────────────────────────────
  Future<void> init();
  void dispose();

  // ── الصلاحيات ───────────────────────────────────────────────
  Future<bool> requestPermission();
  Future<bool> requestNotificationPermission() async => true;

  // ── الاتصال ─────────────────────────────────────────────────
  Future<void> connect(VpnConfig config);
  Future<void> disconnect();

  // ── الحالة ──────────────────────────────────────────────────
  Stream<VpnState> get stateStream;
  VpnState get currentState;
  Future<void> refreshState() async {}

  /// هل النفق "مفتوح" من منظور النظام؟ (لا يعني أنه يمرر ترافيك)
  Future<bool> isConnected();

  // ── صحة النفق ───────────────────────────────────────────────
  /// فحص سريع لصحة النفق (مثلاً ping داخل النفق، أو عدّاد bytes).
  ///
  /// ⚠️ التنفيذ الافتراضي ضعيف (يعتمد على isConnected فقط).
  /// يُوصى بتجاوزه في كل تنفيذ فعلي للجسر:
  /// - WireGuard: آخر handshake < 180s → good
  /// - OpenVPN: byte counter يزداد → good
  /// - Windows: ping داخل النفق → good
  Future<LinkHealth> probeHealth() async =>
      (await isConnected()) ? LinkHealth.good : LinkHealth.down;

  /// بث تغيّرات صحة النفق إن كان الجسر يدعمها.
  /// إن لم يدعمها، اتركه فارغاً والـ controller سيستعمل probeHealth().
  Stream<LinkHealth> get healthStream => const Stream.empty();

  // ── تغيّر الشبكة ────────────────────────────────────────────
  /// يُستدعى فقط عند تغيّر شبكة **حقيقي** (WiFi→LTE، عودة من انقطاع طويل).
  ///
  /// العقد:
  /// - **idempotent**: نفس [networkKey] = لا شيء يحدث.
  /// - **لا يقطع الاتصال** إن أمكن (WireGuard: تحديث endpoint فقط).
  /// - OpenVPN قد يعيد الاتصال؛ مقبول لكن يجب أن ينعكس في [stateStream].
  Future<void> onNetworkChanged({String? networkKey}) async {}

  // ── Kill Switch ─────────────────────────────────────────────
  /// عند التفعيل: يُمنع كل الترافيك عدا واجهة النفق.
  /// عند التعطيل: يُرفع المنع.
  ///
  /// يجب أن يكون idempotent — استدعاؤه مرتين بنفس القيمة = لا شيء.
  /// التنفيذ الافتراضي no-op (للجسور التي لا تدعمه).
  Future<void> setKillSwitch(bool enabled) async {}

  /// هل الـ kill switch مفعّل حالياً على مستوى النظام؟
  Future<bool> isKillSwitchActive() async => false;

  // ── Autostart / Always-on (Android فقط) ─────────────────────
  /// هل التشغيل التلقائي عند الإقلاع مفعّل؟ (Android فقط)
  Future<bool> getAutostart() async => false;

  /// تفعيل/تعطيل التشغيل التلقائي عند الإقلاع.
  Future<void> setAutostart(bool enabled) async {}

  /// فتح إعدادات Always-on VPN في النظام.
  Future<bool> openAlwaysOnSettings() async => false;

  /// طلب إعفاء من تحسين البطارية.
  Future<bool> requestBatteryOptimizationExemption() async => false;

  // ── إضافات ──────────────────────────────────────────────────
  Future<String> getNotificationErrorLog() async => '';
  Future<bool> clearNotificationErrorLog() async => false;
  Future<bool> isIgnoringBatteryOptimizations() async => false;
  Future<bool> openAppSettings() async => false;
  Future<Map<String, dynamic>?> getLastConfig() async => null;
  Future<void> clearLastConfig() async {}
}
