import 'dart:async';
import 'package:flutter/services.dart';
import '../models/vpn_config.dart';

/// حدث يصل من الطبقة الأصلية
class NativeVpnEvent {
  final String state; // connecting | connected | disconnecting | disconnected | error
  final String? message;
  final String? configName;
  NativeVpnEvent(this.state, this.message, {this.configName});
}

class VpnPlatformService {
  // ⚠️ يجب أن تطابق MainActivity.kt تماماً
  static const _method = MethodChannel('com.example.myvpn/vpn');
  static const _events = EventChannel('com.example.myvpn/vpn_events');

  /// بث تحديثات الحالة من VpnStateBus
  Stream<NativeVpnEvent> get stateStream {
    return _events.receiveBroadcastStream().map((e) {
      // VpnStateBus.snapshot() يعيد Map — لكن الأحداث عبر sink.success
      // قد تكون Map أو String. نتعامل مع الحالتين بأمان.
      if (e is Map) {
        final map = Map<String, dynamic>.from(e);
        return NativeVpnEvent(
          (map['state'] as String?) ?? 'disconnected',
          map['message'] as String?,
          configName: map['configName'] as String?,
        );
      }
      // في حال كانت String (خطأ مباشر)
      return NativeVpnEvent('error', e.toString());
    });
  }

  // ------------------------------------------------------------------
  // صلاحيات
  // ------------------------------------------------------------------

  /// يطلب صلاحية VPN. يعيد true إذا مُنحت.
  Future<bool> requestVpnPermission() async {
    try {
      final result = await _method.invokeMethod<bool>('prepare');
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'BUSY') {
        throw StateError('طلب صلاحية VPN قيد التنفيذ بالفعل');
      }
      rethrow;
    }
  }

  /// يطلب صلاحية الإشعارات (Android 13+). يعيد true إذا مُنحت.
  Future<bool> requestNotificationPermission() async {
    try {
      final result =
          await _method.invokeMethod<bool>('requestNotificationPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // اتصال
  // ------------------------------------------------------------------

  /// يبدأ الاتصال. يعيد true إذا نجح.
  /// يرمي PlatformException مع code=NO_NOTIFICATION_PERMISSION إذا كانت
  /// صلاحية الإشعارات مرفوضة على Android 13+.
  /// يرمي PlatformException مع code=NO_PERMISSION إذا كانت صلاحية VPN مرفوضة.
  Future<bool> connect(VpnConfig cfg) async {
    try {
      final ok = await _method.invokeMethod<bool>('connect', cfg.toMap());
      return ok ?? false;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'NO_NOTIFICATION_PERMISSION':
          throw VpnException(
            'صلاحية الإشعارات مطلوبة لتشغيل VPN. اسمح بها من الإعدادات.',
            code: e.code,
          );
        case 'NO_PERMISSION':
          throw VpnException(
            'صلاحية VPN مطلوبة. اطلبها أولاً عبر requestVpnPermission().',
            code: e.code,
          );
        case 'START_FAILED':
          throw VpnException(
            'فشل بدء الخدمة: ${e.message}',
            code: e.code,
          );
        default:
          rethrow;
      }
    }
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  Future<bool> isConnected() async {
    return await _method.invokeMethod<bool>('isConnected') ?? false;
  }

  Future<void> kick() async {
    await _method.invokeMethod('kick');
  }

  Future<Map<String, dynamic>?> getState() async {
    final result = await _method.invokeMethod<Map>('getState');
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<String?> getPendingError() async {
    return await _method.invokeMethod<String>('getPendingError');
  }

  // ------------------------------------------------------------------
  // إعدادات النظام
  // ------------------------------------------------------------------

  Future<bool> getAutostart() async {
    return await _method.invokeMethod<bool>('getAutostart') ?? false;
  }

  Future<void> setAutostart(bool enabled) async {
    await _method.invokeMethod('setAutostart', {'enabled': enabled});
  }

  Future<bool> openAlwaysOnSettings() async {
    return await _method.invokeMethod<bool>('openAlwaysOnSettings') ?? false;
  }

  Future<bool> openBatteryOptimizationSettings() async {
    return await _method.invokeMethod<bool>(
            'openBatteryOptimizationSettings') ??
        false;
  }

  // ------------------------------------------------------------------
  // سجل أخطاء الإشعارات
  // ------------------------------------------------------------------

  /// قراءة سجل أخطاء الإشعارات (نص خام)
  Future<String> getNotificationErrorLog() async {
    try {
      final result =
          await _method.invokeMethod<String>('getNotificationErrorLog');
      return result ?? '';
    } on PlatformException catch (e) {
      return 'فشل قراءة السجل: ${e.message}';
    }
  }

  /// مسح سجل أخطاء الإشعارات
  Future<bool> clearNotificationErrorLog() async {
    try {
      final result =
          await _method.invokeMethod<bool>('clearNotificationErrorLog');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}

/// استثناء مخصص لأخطاء VPN مع رمز واضح
class VpnException implements Exception {
  final String message;
  final String? code;
  VpnException(this.message, {this.code});

  @override
  String toString() => 'VpnException($code): $message';
}
