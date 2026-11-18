import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show PlatformException;

import '../models/vpn_config.dart';
import '../models/vpn_log.dart';
import '../models/vpn_state.dart';
import '../services/config_store.dart';
import '../services/internet_check.dart';
import '../services/session_persister.dart';
import '../services/vpn_bridge.dart';

class VpnController extends ChangeNotifier {
  final VpnBridge bridge;
  final ConfigStore store = ConfigStore();
  final SessionPersister _session = SessionPersister();

  StreamSubscription<VpnState>? _stateSub;
  Timer? _networkWatchdog;
  bool _wasConnectedBeforeOutage = false;
  bool _autoReconnectEnabled = true;

  // ✅ آخر حالة معروفة — لمقارنة refreshState الهادئ
  VpnStatus? _lastLoggedStatus;

  final List<VpnLog> _logs = [];
  List<VpnLog> get logs => List.unmodifiable(_logs);

  VpnController(this.bridge) {
    _stateSub = bridge.stateStream.listen(_onStateChanged);
    _startNetworkWatchdog();
    _bootstrap();
  }

  // ------------------------- Bootstrap -------------------------

  Future<void> _bootstrap() async {
    log('controller initialized');
    await restoreSession();
  }

  Future<void> restoreSession() async {
    final saved = await _session.load();
    final s = state;

    if (s.status != VpnStatus.connected) {
      if (saved != null) {
        log('stale session found (state=${s.status.name}) → cleared',
            level: LogLevel.warn);
        await _session.clear();
      }
      return;
    }

    if (saved == null) {
      log('connected but no saved session → synthesizing since=now',
          level: LogLevel.warn);
      await _session.save(
        since: DateTime.now(),
        configName: s.activeConfigName ?? 'unknown',
      );
      notifyListeners();
      return;
    }

    log('restored session: ${saved.configName} since ${saved.since}');
    notifyListeners();
  }

  /// يطلب الحالة الحقيقية من الجسر.
  /// ✅ هادئ: لا يسجّل شيئاً إن لم تتغيّر الحالة فعلياً.
  Future<void> refreshState() async {
    final before = state;
    await bridge.refreshState();
    final after = state;

    final changed = before.status != after.status ||
        before.connectedSince != after.connectedSince ||
        before.activeConfigName != after.activeConfigName ||
        before.errorMessage != after.errorMessage;

    if (changed) {
      log('refreshState → ${after.status.name}');
      await restoreSession();
    }
    // لا نُسجّل ولا نُنبّه إن لم يتغيّر شيء
  }

  // ------------------------- Logs -------------------------

  void log(String message, {LogLevel level = LogLevel.info}) {
    _logs.add(VpnLog(message, level: level));
    if (_logs.length > 500) _logs.removeAt(0);
    final tag = switch (level) {
      LogLevel.info => 'INFO ',
      LogLevel.warn => 'WARN ',
      LogLevel.error => 'ERROR',
    };
    debugPrint('[VPN $tag] $message');
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // ------------------------- Getters -------------------------

  VpnState get state => bridge.currentState;

  bool get autoReconnectEnabled => _autoReconnectEnabled;
  set autoReconnectEnabled(bool v) {
    _autoReconnectEnabled = v;
    log('autoReconnect = $v');
    notifyListeners();
  }

  // ------------------------- State events -------------------------

  void _onStateChanged(VpnState s) {
    // ✅ نسجّل فقط عند تغيّر فعلي في الحالة (تفادي تكرار السجلات)
    if (_lastLoggedStatus != s.status || s.errorMessage != null) {
      log('state → ${s.status.name}'
          '${s.errorMessage != null ? " (${s.errorMessage})" : ""}');
      _lastLoggedStatus = s.status;
    }

    if (s.status == VpnStatus.connected) {
      _wasConnectedBeforeOutage = true;
      _persistSession();
    }
    // ⚠️ لا نمسح الجلسة هنا — نتركها لـ disconnect() الصريح
    // (حتى لا تُفقد connectedSince عند انقطاع لحظي/إعادة اتصال تلقائي)

    notifyListeners();
  }

  Future<void> _persistSession() async {
    final s = state;
    if (s.status != VpnStatus.connected) return;
    final since = s.connectedSince ?? DateTime.now();
    final name = s.activeConfigName ?? 'unknown';
    await _session.save(since: since, configName: name);
    log('session persisted ($name, since=$since)');
  }

  // ------------------------- Watchdog -------------------------

  void _startNetworkWatchdog() {
    _networkWatchdog?.cancel();
    _networkWatchdog = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_autoReconnectEnabled) return;
      if (state.status != VpnStatus.connected) return;
      if (!_wasConnectedBeforeOutage) return;
      final online = await hasInternet();
      if (!online) return;
      try {
        await bridge.onNetworkChanged();
      } catch (e) {
        log('watchdog error: $e', level: LogLevel.error);
      }
    });
  }

  // ------------------------- Connect / Disconnect -------------------------

  Future<bool> connect(VpnConfig config) async {
    log('connect requested: ${config.name} → ${config.endpoint}');

    try {
      final notifOk = await bridge.requestNotificationPermission()
          .timeout(const Duration(seconds: 30));
      log('notification permission: $notifOk');
    } catch (e) {
      log('notification permission error: $e', level: LogLevel.warn);
    }

    log('checking VPN permission...');
    bool granted;
    try {
      granted = await bridge.requestPermission()
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      log('permission error: $e', level: LogLevel.error);
      return false;
    }
    if (!granted) {
      log('permission denied', level: LogLevel.warn);
      return false;
    }
    log('permission granted');

    log('starting tunnel...');
    try {
      await bridge.connect(config).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          log('connect timeout (30s)', level: LogLevel.error);
          throw TimeoutException('connect timeout');
        },
      );
      log('connect() returned');
      return true;
    } on PlatformException catch (e) {
      log('PlatformException: ${e.code} ${e.message}', level: LogLevel.error);
      return false;
    } on TimeoutException {
      return false;
    } catch (e) {
      log('connect error: $e', level: LogLevel.error);
      return false;
    }
  }

  Future<void> disconnect() async {
    log('disconnect requested');
    _wasConnectedBeforeOutage = false;
    try {
      await bridge.disconnect().timeout(const Duration(seconds: 10));
    } catch (e) {
      log('disconnect error: $e', level: LogLevel.error);
    }
    await _session.clear();
    log('session cleared');
  }

  @override
  void dispose() {
    _networkWatchdog?.cancel();
    _stateSub?.cancel();
    bridge.dispose();
    super.dispose();
  }
}
