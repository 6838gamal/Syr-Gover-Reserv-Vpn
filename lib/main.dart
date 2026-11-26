import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'models/vpn_config.dart';
import 'models/vpn_state.dart';
import 'services/config_store.dart';
import 'services/internet_check.dart';
import 'services/vpn_bridge.dart';
import 'services/vpn_bridge_factory.dart';

// =============================================================================
// نماذج مساعدة
// =============================================================================

enum LogLevel { info, warn, error }

class VpnLog {
  final DateTime time;
  final String message;
  final LogLevel level;

  VpnLog(this.message, {this.level = LogLevel.info}) : time = DateTime.now();

  String get formattedTime {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

class SessionPersister {
  static const _kSince = 'vpn.connected_since_ms';
  static const _kConfig = 'vpn.active_config_name';

  Future<void> save({
    required DateTime since,
    required String configName,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSince, since.millisecondsSinceEpoch);
    await p.setString(_kConfig, configName);
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSince);
    await p.remove(_kConfig);
  }

  Future<({DateTime since, String configName})?> load() async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_kSince);
    final name = p.getString(_kConfig);
    if (ms == null || name == null) return null;
    return (
      since: DateTime.fromMillisecondsSinceEpoch(ms),
      configName: name as String,
    );
  }
}

// =============================================================================
// VpnController
// =============================================================================

class VpnController extends ChangeNotifier {
  final VpnBridge bridge;
  final ConfigStore store = ConfigStore();
  final SessionPersister _session = SessionPersister();

  StreamSubscription<VpnState>? _stateSub;

  // ── Connectivity watcher (بدون تبعية) ────────────────────────────
  Timer? _connectivityTimer;
  Timer? _persistDebounce;

  bool _lastInternetOk = true;
  DateTime? _outageStart;
  DateTime? _lastKickAt;

  static const _minKickInterval = Duration(seconds: 30);
  static const _checkInterval = Duration(seconds: 20);

  bool _wasConnectedBeforeOutage = false;
  bool _autoReconnectEnabled = true;

  // ── cache الصلاحيات ─────────────────────────────────────────────
  bool? _vpnPermissionCache;

  final List<VpnLog> _logs = [];
  List<VpnLog> get logs => List.unmodifiable(_logs);

  VpnController(this.bridge) {
    _stateSub = bridge.stateStream.listen(_onStateChanged);
    _startConnectivityWatcher();
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
      final name = s.activeConfigName ?? 'unknown';
      log('connected but no saved session → synthesizing since=now ($name)',
          level: LogLevel.warn);
      await _session.save(since: DateTime.now(), configName: name);
      notifyListeners();
      return;
    }

    log('restored session: ${saved.configName} since ${saved.since}');
    notifyListeners();
  }

  Future<void> refreshState() async {
    log('refreshState requested');
    await bridge.refreshState();
    await restoreSession();
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
    // ❌ لا notifyListeners هنا — يُستدعى من _onStateChanged
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
    log('state → ${s.status.name}'
        '${s.errorMessage != null ? " (${s.errorMessage})" : ""}');
    if (s.status == VpnStatus.connected) {
      _wasConnectedBeforeOutage = true;
      _persistDebounce?.cancel();
      _persistDebounce = Timer(
        const Duration(milliseconds: 500),
        _persistSession,
      );
    } else if (s.status == VpnStatus.disconnected ||
        s.status == VpnStatus.error) {
      _persistDebounce?.cancel();
      _persistDebounce = null;
      _wasConnectedBeforeOutage = false;
      _session.clear();
    }
    notifyListeners();
  }

  Future<void> _persistSession() async {
    final s = state;
    if (s.status != VpnStatus.connected) return;

    String name = s.activeConfigName ?? 'unknown';
    if (name == 'unknown') {
      final saved = await _session.load();
      if (saved != null && saved.configName != 'unknown') {
        name = saved.configName;
      }
    }

    final since = s.connectedSince ?? DateTime.now();
    await _session.save(since: since, configName: name);
    log('session persisted ($name, since=$since)');
  }

  // ------------------------- Connectivity Watcher -------------------------

  void _startConnectivityWatcher() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(_checkInterval, (_) async {
      await _checkConnectivity();
    });
  }

  Future<void> _checkConnectivity() async {
    if (!_autoReconnectEnabled) return;
    if (state.status != VpnStatus.connected) {
      _lastInternetOk = true;
      _outageStart = null;
      return;
    }

    final online = await hasInternet();
    final now = DateTime.now();

    if (!online) {
      // ── انقطاع: سجّل وقت البداية فقط، لا kick ──
      if (_lastInternetOk) {
        _outageStart = now;
        log('network outage detected', level: LogLevel.warn);
      }
      _lastInternetOk = false;
      return;
    }

    // ── الإنترنت موجود ──
    if (!_lastInternetOk) {
      // كان منقطعاً وعاد → kick مرة واحدة
      _lastInternetOk = true;
      final outageDuration = _outageStart != null
          ? now.difference(_outageStart!)
          : Duration.zero;
      _outageStart = null;
      log('network restored after ${outageDuration.inSeconds}s → kicking');

      if (_canKick()) {
        _lastKickAt = now;
        try {
          await bridge.onNetworkChanged();
        } catch (e) {
          log('kick failed: $e', level: LogLevel.error);
        }
      }
      return;
    }

    // ── إنترنت موجود باستمرار → لا kick ──
    // (لا شيء — هذا هو الوضع الطبيعي)
  }

  bool _canKick() {
    if (_lastKickAt == null) return true;
    return DateTime.now().difference(_lastKickAt!) >= _minKickInterval;
  }

  // ------------------------- Connect / Disconnect -------------------------

  Future<bool> connect(VpnConfig config) async {
    log('connect requested: ${config.name} → ${config.endpoint}');

    // 0) Windows elevation
    if (Platform.isWindows && !await WindowsElevation.isAdmin()) {
      log('not running as administrator → requesting elevation',
          level: LogLevel.warn);
      final elevated = await WindowsElevation.requestElevationAndExit();
      if (!elevated) {
        log('elevation declined or failed', level: LogLevel.error);
        return false;
      }
      return false;
    }

    // 1) صلاحية الإشعارات (لا نُفشل الاتصال إن رُفضت)
    try {
      final notifOk = await bridge.requestNotificationPermission()
          .timeout(const Duration(seconds: 30));
      log('notification permission: $notifOk');
    } catch (e) {
      log('notification permission error: $e', level: LogLevel.warn);
    }

    // 2) صلاحية VPN — مع cache
    log('checking VPN permission...');
    bool granted;
    try {
      if (_vpnPermissionCache == true) {
        granted = true;
      } else {
        granted = await bridge.requestPermission()
            .timeout(const Duration(seconds: 60));
        _vpnPermissionCache = granted;
      }
    } catch (e) {
      log('permission error: $e', level: LogLevel.error);
      _vpnPermissionCache = null; // ← اسمح بإعادة المحاولة
      return false;
    }
    if (!granted) {
      log('permission denied', level: LogLevel.warn);
      return false;
    }
    log('permission granted');

    // 3) الاتصال
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
      // إذا فشل الاتصال، امسح cache الصلاحية (قد تكون سُحبت)
      if (e.code == 'NO_PERMISSION') _vpnPermissionCache = null;
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
    _lastInternetOk = true;
    _outageStart = null;
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
    _connectivityTimer?.cancel();
    _persistDebounce?.cancel();
    _stateSub?.cancel();
    // ✅ لا تستدعِ bridge.dispose() — الـ singleton يُعاش
    super.dispose();
  }
}

// =============================================================================
// WindowsElevation — كما هو (بدون تغيير)
// =============================================================================

class WindowsElevation {
  static Future<bool> isAdmin() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run('net', ['session'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestElevationAndExit() async {
    if (!Platform.isWindows) return true;
    try {
      final exePath = Platform.resolvedExecutable;
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Start-Process -FilePath "$exePath" -Verb RunAs',
        ],
      ).timeout(const Duration(seconds: 30));

      if (r.exitCode == 0) {
        await Future.delayed(const Duration(milliseconds: 300));
        exit(0);
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

// =============================================================================
// main() — كما هو (بدون تغيير)
// =============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final admin = await WindowsElevation.isAdmin();
    if (!admin) {
      final elevated = await WindowsElevation.requestElevationAndExit();
      if (!elevated) {
        runApp(const _ElevationRequiredApp());
        return;
      }
      return;
    }
  }

  final VpnBridge bridge = createVpnBridge();

  try {
    await bridge.init();
  } catch (e, st) {
    runApp(_BootstrapErrorApp(message: e.toString(), stack: st.toString()));
    return;
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<VpnBridge>.value(value: bridge),
        ChangeNotifierProvider(create: (_) => VpnController(bridge)),
      ],
      child: const MyVpnApp(),
    ),
  );
}

// =============================================================================
// _ElevationRequiredApp و _BootstrapErrorApp — كما هما (بدون تغيير)
// =============================================================================

class _ElevationRequiredApp extends StatelessWidget {
  const _ElevationRequiredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF59E0B),
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings,
                    size: 72, color: Colors.amber),
                const SizedBox(height: 20),
                const Text(
                  'صلاحيات المسؤول مطلوبة',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'لتشغيل VPN على Windows، يحتاج التطبيق إلى صلاحيات مسؤول.\n\n'
                  'أغلق التطبيق ثم شغّله بزر الفأرة الأيمن → "Run as administrator"،\n'
                  'أو اضغط الزر أدناه لرفع الصلاحيات الآن.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, height: 1.6),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.lock_open),
                  label: const Text('رفع الصلاحيات والمحاولة مجدداً'),
                  onPressed: () async {
                    await WindowsElevation.requestElevationAndExit();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BootstrapErrorApp extends StatelessWidget {
  final String message;
  final String stack;
  const _BootstrapErrorApp({required this.message, required this.stack});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFEF4444),
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'فشل بدء التشغيل',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    stack,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
