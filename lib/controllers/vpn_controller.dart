import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/vpn_config.dart';
import '../models/vpn_log.dart';
import '../models/vpn_state.dart';
import '../services/vpn_service.dart';
import '../services/session_persister.dart';

class VpnController extends ChangeNotifier {
  final VpnPlatformService _platform;
  final ConfigStore store;
  final SessionPersister _session;

  VpnState _state = const VpnState();
  VpnState get state => _state;

  bool autoReconnectEnabled = false;

  final List<VpnLog> _logs = [];
  List<VpnLog> get logs => List.unmodifiable(_logs);

  StreamSubscription<NativeVpnEvent>? _sub;

  VpnController({
    required VpnPlatformService platform,
    required this.store,
    SessionPersister? session,
  })  : _platform = platform,
        _session = session ?? SessionPersister() {
    _init();
  }

  Future<void> _init() async {
    log('controller initialized');
    _sub = _platform.stateStream.listen(
      _onNativeEvent,
      onError: (e) => log('event stream error: $e', level: LogLevel.error),
    );
    await restoreSession();
  }

  // ---------------------- استعادة الجلسة ----------------------

  /// تُستدعى عند بدء التطبيق. تتحقق من الطبقة الأصلية أولاً
  /// حتى لا نعيد حالة "متصل" وهمية.
  Future<void> restoreSession() async {
    final saved = await _session.load();
    final actuallyConnected = await _platform.isConnected();

    if (!actuallyConnected) {
      if (saved != null) {
        log('stale session found (not actually connected) → cleared',
            level: LogLevel.warn);
        await _session.clear();
      }
      _setState(const VpnState(status: VpnStatus.disconnected));
      return;
    }

    if (saved == null) {
      // الطبقة الأصلية تقول متصل لكن لا جلسة محفوظة (حالة غير متوقعة)
      log('native says connected but no saved session', level: LogLevel.warn);
      _setState(const VpnState(
        status: VpnStatus.connected,
        connectedSince: null,
      ));
      return;
    }

    log('restored session: ${saved.configName} since ${saved.since}');
    _setState(VpnState(
      status: VpnStatus.connected,
      activeConfigName: saved.configName,
      connectedSince: saved.since,
    ));
  }

  // ---------------------- Event handling ----------------------

  void _onNativeEvent(NativeVpnEvent ev) {
    log('native → ${ev.state}${ev.message != null ? " (${ev.message})" : ""}');
    switch (ev.state) {
      case 'connected':
        _setState(_state.toStatus(VpnStatus.connected));
        _persistCurrentSession();
        break;
      case 'connecting':
        _setState(_state.toStatus(VpnStatus.connecting));
        break;
      case 'disconnecting':
        _setState(_state.toStatus(VpnStatus.disconnecting));
        break;
      case 'disconnected':
        _setState(_state.toStatus(VpnStatus.disconnected));
        _session.clear();
        break;
      case 'error':
        _setState(_state.toStatus(VpnStatus.error, errorMessage: ev.message));
        _session.clear();
        break;
    }
  }

  /// يحفظ الجلسة إن كانت الحالة متصلة.
  Future<void> _persistCurrentSession() async {
    if (_state.status == VpnStatus.connected &&
        _state.connectedSince != null &&
        _state.activeConfigName != null) {
      await _session.save(
        since: _state.connectedSince!,
        configName: _state.activeConfigName!,
      );
      log('session persisted');
    }
  }

  // ---------------------- Logging ----------------------

  void log(String message, {LogLevel level = LogLevel.info}) {
    final entry = VpnLog(message, level: level);
    _logs.add(entry);
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

  void _setState(VpnState s) {
    _state = s;
    notifyListeners();
  }

  // ---------------------- Connect / Disconnect ----------------------

  Future<bool> connect(VpnConfig cfg) async {
    log('connect requested: ${cfg.name} → ${cfg.endpoint}');
    _setState(_state.toStatus(VpnStatus.connecting, activeConfigName: cfg.name));

    bool granted;
    try {
      granted = await _platform.requestPermission()
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      log('permission error: $e', level: LogLevel.error);
      _fail('permission error: $e');
      return false;
    }
    if (!granted) {
      log('permission denied by user', level: LogLevel.warn);
      _fail('تم رفض صلاحية VPN');
      return false;
    }
    log('permission granted');

    log('starting tunnel...');
    try {
      final ok = await _platform.connect(cfg)
          .timeout(const Duration(seconds: 30), onTimeout: () {
        log('connect timeout (30s)', level: LogLevel.error);
        return false;
      });
      if (!ok) {
        log('connect returned false', level: LogLevel.error);
        _fail('فشل بدء النفق');
        return false;
      }
      _setState(_state.toStatus(VpnStatus.connected, activeConfigName: cfg.name));
      await _persistCurrentSession();
      log('tunnel established');
      return true;
    } on PlatformException catch (e) {
      log('PlatformException: ${e.code} ${e.message}', level: LogLevel.error);
      _fail('${e.code}: ${e.message ?? ''}');
      return false;
    } catch (e) {
      log('connect error: $e', level: LogLevel.error);
      _fail(e.toString());
      return false;
    }
  }

  Future<void> disconnect() async {
    log('disconnect requested');
    _setState(_state.toStatus(VpnStatus.disconnecting));
    try {
      await _platform.disconnect().timeout(const Duration(seconds: 10));
    } catch (e) {
      log('disconnect error: $e', level: LogLevel.error);
    }
    _setState(_state.toStatus(VpnStatus.disconnected));
    await _session.clear();
    log('session cleared');
  }

  void _fail(String msg) {
    _setState(_state.toStatus(VpnStatus.error, errorMessage: msg));
    _session.clear();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
