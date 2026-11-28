import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show PlatformException;

import '../models/vpn_config.dart';
import '../models/vpn_log.dart';
import '../models/vpn_state.dart';
import '../services/config_store.dart';
import '../services/network_identity.dart';
import '../services/session_persister.dart';
import '../services/vpn_bridge.dart';

class VpnController extends ChangeNotifier {
  final VpnBridge bridge;
  final ConfigStore store = ConfigStore();
  final SessionPersister _session = SessionPersister();

  StreamSubscription<VpnState>? _stateSub;
  StreamSubscription<LinkHealth>? _healthSub;
  StreamSubscription<String?>? _networkSub;
  Timer? _networkWatchdog;

  // ── صحة الرابط ──────────────────────────────────────────────
  LinkHealth _linkHealth = LinkHealth.unknown;
  LinkHealth get linkHealth => _linkHealth;
  bool get isNetworkUntrusted => _linkHealth == LinkHealth.down;

  int _consecutiveFails = 0;
  static const _failsBeforeDown = 3; // 3×10s = 30s قبل إعلان الانقطاع

  DateTime? _outageStart;
  DateTime? _lastKickAt;
  String? _lastNetworkKey;

  static const _minKickInterval = Duration(seconds: 90);
  static const _restartAfterOutage = Duration(seconds: 60);
  static const _watchdogInterval = Duration(seconds: 10);

  // ── إعدادات ─────────────────────────────────────────────────
  bool _autoReconnectEnabled = true;
  bool get autoReconnectEnabled => _autoReconnectEnabled;
  set autoReconnectEnabled(bool v) {
    _autoReconnectEnabled = v;
    log('autoReconnect = $v');
    notifyListeners();
  }

  bool _killSwitchEnabled = true;
  bool get killSwitchEnabled => _killSwitchEnabled;
  set killSwitchEnabled(bool v) {
    _killSwitchEnabled = v;
    log('killSwitch = $v');
    _syncKillSwitch(v && _linkHealth == LinkHealth.down);
    notifyListeners();
  }

  // ── آخر حالة معروفة (refreshState الهادئ) ───────────────────
  VpnStatus? _lastLoggedStatus;

  // ── تسلسل العمليات ──────────────────────────────────────────
  Future<void> _opChain = Future.value();
  Future<T> _serialize<T>(Future<T> Function() op) {
    final prev = _opChain;
    final completer = Completer<T>();
    _opChain = prev.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ── السجلات ─────────────────────────────────────────────────
  final List<VpnLog> _logs = [];
  List<VpnLog> get logs => List.unmodifiable(_logs);

  VpnController(this.bridge) {
    _stateSub = bridge.stateStream.listen(_onStateChanged);
    _healthSub = bridge.healthStream.listen(_applyHealthFromStream);
    _networkSub =
        NetworkIdentity.watch().listen(_onNetworkIdentityChanged);
    _startNetworkWatchdog();
    _bootstrap();
  }

  // ===========================================================================
  // Bootstrap
  // ===========================================================================

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
  }

  // ===========================================================================
  // السجلات
  // ===========================================================================

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

  VpnState get state => bridge.currentState;

  // ===========================================================================
  // أحداث الحالة
  // ===========================================================================

  void _onStateChanged(VpnState s) {
    if (_lastLoggedStatus != s.status || s.errorMessage != null) {
      log('state → ${s.status.name}'
          '${s.errorMessage != null ? " (${s.errorMessage})" : ""}');
      _lastLoggedStatus = s.status;
    }

    if (s.status == VpnStatus.connected) {
      if (_linkHealth == LinkHealth.unknown) {
        _linkHealth = LinkHealth.good;
      }
      _persistSession();
    } else if (s.status == VpnStatus.disconnected ||
        s.status == VpnStatus.error) {
      _resetHealth();
    }

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

  // ===========================================================================
  // تغيّر هوية الشبكة — استجابة فورية (بدون kick)
  // ===========================================================================

  void _onNetworkIdentityChanged(String? key) {
    if (key == null || key == _lastNetworkKey) return;
    final prev = _lastNetworkKey;
    _lastNetworkKey = key;
    log('network identity: $prev → $key', level: LogLevel.warn);

    if (!_autoReconnectEnabled) return;
    if (state.status != VpnStatus.connected) return;

    // تغيّر الشبكة = بداية انقطاع محتمل. لا kick الآن.
    // الـ watchdog سيتحقق عبر probeHealth() ويعلن good/down.
    _applyHealth(LinkHealth.suspect);
  }

  // ===========================================================================
  // Watchdog + صحة النفق
  // ===========================================================================

  void _startNetworkWatchdog() {
    _networkWatchdog?.cancel();
    _networkWatchdog = Timer.periodic(_watchdogInterval, (_) async {
      await _serialize(_tickWatchdog);
    });
  }

  Future<void> _tickWatchdog() async {
    if (!_autoReconnectEnabled) return;

    if (state.status != VpnStatus.connected) {
      _resetHealth();
      return;
    }

    // صحة النفق من الجسر (يدرك حالة النفق الفعلية، لا الإنترنت العام)
    LinkHealth h;
    try {
      h = await bridge.probeHealth();
    } catch (e) {
      log('probeHealth error: $e', level: LogLevel.warn);
      h = LinkHealth.suspect;
    }

    // تحديث networkKey إن لم يصلنا البث (fallback)
    final key = await NetworkIdentity.currentKey();
    if (key != null && key != _lastNetworkKey) {
      _lastNetworkKey = key;
    }

    _applyHealth(h);
  }

  void _applyHealthFromStream(LinkHealth h) {
    _applyHealth(h, fromStream: true);
  }

  void _applyHealth(LinkHealth h, {bool fromStream = false}) {
    final now = DateTime.now();

    switch (h) {
      case LinkHealth.down:
        if (!fromStream) _consecutiveFails++;
        final enough = fromStream || _consecutiveFails >= _failsBeforeDown;

        if (enough && _linkHealth != LinkHealth.down) {
          _linkHealth = LinkHealth.down;
          _outageStart = now;
          log('tunnel DOWN → block traffic', level: LogLevel.warn);
          _syncKillSwitch(true);
          notifyListeners();
        }

      case LinkHealth.suspect:
        if (!fromStream) _consecutiveFails++;
        if (_linkHealth == LinkHealth.good) {
          _linkHealth = LinkHealth.suspect;
          log('tunnel suspect', level: LogLevel.warn);
          notifyListeners();
        }

      case LinkHealth.good:
        _consecutiveFails = 0;
        if (_linkHealth == LinkHealth.down) {
          final outage = _outageStart != null
              ? now.difference(_outageStart!)
              : Duration.zero;
          _outageStart = null;
          _linkHealth = LinkHealth.good;
          _syncKillSwitch(false);

          if (outage >= _restartAfterOutage && _canKick()) {
            _lastKickAt = now;
            log('long outage (${outage.inSeconds}s) → onNetworkChanged',
                level: LogLevel.warn);
            unawaited(_safeKick());
          } else {
            log('network restored after ${outage.inSeconds}s — no restart');
          }
          notifyListeners();
        } else if (_linkHealth != LinkHealth.good) {
          _linkHealth = LinkHealth.good;
          notifyListeners();
        }

      case LinkHealth.unknown:
        break;
    }
  }

  Future<void> _safeKick() async {
    try {
      await bridge.onNetworkChanged(networkKey: _lastNetworkKey);
    } catch (e) {
      log('onNetworkChanged error: $e', level: LogLevel.error);
    }
  }

  Future<void> _syncKillSwitch(bool on) async {
    if (!_killSwitchEnabled && on) return;
    try {
      await bridge.setKillSwitch(on);
      log('killSwitch → $on');
    } catch (e) {
      log('setKillSwitch error: $e', level: LogLevel.error);
    }
  }

  void _resetHealth() {
    final wasDown = _linkHealth == LinkHealth.down;
    if (_consecutiveFails != 0 ||
        _linkHealth == LinkHealth.down ||
        _linkHealth == LinkHealth.suspect) {
      _consecutiveFails = 0;
      _linkHealth = LinkHealth.good;
      _outageStart = null;
      notifyListeners();
    }
    if (wasDown) {
      unawaited(_syncKillSwitch(false));
    }
  }

  bool _canKick() {
    if (_lastKickAt == null) return true;
    return DateTime.now().difference(_lastKickAt!) >= _minKickInterval;
  }

  // ===========================================================================
  // الاتصال / الفصل
  // ===========================================================================

  Future<bool> connect(VpnConfig config) {
    return _serialize(() => _doConnect(config));
  }

  Future<bool> _doConnect(VpnConfig config) async {
    log('connect requested: ${config.name} → ${config.endpoint}');

    _resetHealth();
    _lastKickAt = null;
    _lastNetworkKey = await NetworkIdentity.currentKey();

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
      _linkHealth = LinkHealth.good;
      log('connect() returned');
      return true;
    } on PlatformException catch (e) {
      log('PlatformException: ${e.code} ${e.message}', level: LogLevel.error);
      _resetHealth();
      return false;
    } on TimeoutException {
      _resetHealth();
      return false;
    } catch (e) {
      log('connect error: $e', level: LogLevel.error);
      _resetHealth();
      return false;
    }
  }

  Future<void> disconnect() {
    return _serialize(() async {
      log('disconnect requested');
      _resetHealth();
      try {
        await bridge.disconnect().timeout(const Duration(seconds: 10));
      } catch (e) {
        log('disconnect error: $e', level: LogLevel.error);
      }
      await _session.clear();
      log('session cleared');
    });
  }

  // ===========================================================================
  // Dispose
  // ===========================================================================

  @override
  void dispose() {
    _networkWatchdog?.cancel();
    _networkSub?.cancel();
    _healthSub?.cancel();
    _stateSub?.cancel();
    // ❌ لا نستدعي bridge.dispose() — الـ singleton يُعاش
    super.dispose();
  }
}
