import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// يولّد بصمة مستقرة للشبكة الحالية.
/// الهدف: كشف "هل تغيّرت الشبكة فعلاً؟" دون kick متكرر.
///
/// شكل المفتاح:
///   "wifi|MyHome"   — واي فاي مع SSID
///   "wifi|"         — واي فاي بدون SSID (صلاحية مرفوضة أو iOS)
///   "ethernet|"     — إيثرنت
///   "mobile|"       — بيانات الجوال
///   "vpn|"          — نفق VPN فقط
///   "none"          — لا اتصال
class NetworkIdentity {
  static final Connectivity _conn = Connectivity();
  static final NetworkInfo _wifi = NetworkInfo();

  static String? _cached;
  static DateTime? _cachedAt;

  /// كاش 5 ثوانٍ — كافٍ لتفادي استدعاءات متكررة في نفس الدورة.
  static const _cacheTtl = Duration(seconds: 5);

  static Future<String?> currentKey() async {
    final now = DateTime.now();
    if (_cached != null &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < _cacheTtl) {
      return _cached;
    }
    final results = await _conn.checkConnectivity();
    return _computeKey(results);
  }

  static Future<String?> _computeKey(List<ConnectivityResult> results) async {
    if (results.contains(ConnectivityResult.wifi)) {
      String? ssid;
      try {
        ssid = await _wifi.getWifiName();
        if (ssid != null) {
          ssid = ssid.replaceAll('"', '').trim();
          if (ssid.isEmpty || ssid == '<unknown ssid>') ssid = null;
        }
      } catch (_) {
        ssid = null;
      }
      return _set('wifi|${ssid ?? ""}');
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return _set('ethernet|');
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return _set('mobile|');
    }
    if (results.contains(ConnectivityResult.vpn)) {
      return _set('vpn|');
    }
    return _set('none');
  }

  static String? _set(String? v) {
    _cached = v;
    _cachedAt = DateTime.now();
    return v;
  }

  /// بث تغيّرات المفتاح — يُطلق فقط عند تغيّر فعلي (distinct).
  static Stream<String?> watch() {
    return _conn.onConnectivityChanged
        .asyncMap((results) => _computeKey(results))
        .distinct();
  }

  static void invalidate() {
    _cached = null;
    _cachedAt = null;
  }
}
