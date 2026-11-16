import 'dart:async';
import 'package:flutter/services.dart';
import '../models/vpn_config.dart';

/// حدث يصل من الطبقة الأصلية (Android/iOS)
class NativeVpnEvent {
  final String state; // connecting | connected | disconnecting | disconnected | error
  final String? message;
  NativeVpnEvent(this.state, this.message);
}

class VpnPlatformService {
  static const _method = MethodChannel('com.example.myvpn/methods');
  static const _events = EventChannel('com.example.myvpn/events');

  /// بث تحديثات الحالة من الـ VpnService
  Stream<NativeVpnEvent> get stateStream {
    return _events.receiveBroadcastStream().map((e) {
      final map = Map<String, dynamic>.from(e as Map);
      return NativeVpnEvent(
        map['state'] as String? ?? 'disconnected',
        map['message'] as String?,
      );
    });
  }

  /// يطلب صلاحية VPN. يعيد true إذا مُنحت.
  Future<bool> requestPermission() async {
    final result = await _method.invokeMethod<bool>('requestPermission');
    return result ?? false;
  }

  /// يبدأ الاتصال. يعيد true إذا نجح.
  Future<bool> connect(VpnConfig cfg) async {
    final ok = await _method.invokeMethod<bool>('connect', cfg.toMap());
    return ok ?? false;
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  Future<bool> isConnected() async {
    return await _method.invokeMethod<bool>('isConnected') ?? false;
  }
}
