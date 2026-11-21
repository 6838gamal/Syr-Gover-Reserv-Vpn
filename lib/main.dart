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
  Timer? _networkWatchdog;
  bool _wasConnectedBeforeOutage = false;
  bool _autoReconnectEnabled = true;

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
    log('state → ${s.status.name}'
        '${s.errorMessage != null ? " (${s.errorMessage})" : ""}');
    if (s.status == VpnStatus.connected) {
      _wasConnectedBeforeOutage = true;
      _persistSession();
    } else if (s.status == VpnStatus.disconnected ||
        s.status == VpnStatus.error) {
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

    // 0) على Windows: تأكد من صلاحية المسؤول قبل أي محاولة
    if (Platform.isWindows && !await WindowsElevation.isAdmin()) {
      log('not running as administrator → requesting elevation',
          level: LogLevel.warn);
      final elevated = await WindowsElevation.requestElevationAndExit();
      if (!elevated) {
        log('elevation declined or failed', level: LogLevel.error);
        return false;
      }
      // إن نجح، Process سيُستبدل ويعاد التشغيل؛ لن نصل هنا فعلياً
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

    // 2) صلاحية VPN
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

// =============================================================================
// WindowsElevation — طلب الصلاحيات على Windows
// =============================================================================

class WindowsElevation {
  /// هل التطبيق يعمل حالياً كمسؤول؟
  static Future<bool> isAdmin() async {
    if (!Platform.isWindows) return true;
    try {
      // `net session` ينجح فقط للمسؤول
      final r = await Process.run('net', ['session'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// يعيد تشغيل التطبيق عبر UAC ثم يغلق النسخة الحالية.
  /// يعيد false إذا رُفض UAC أو فشل.
  static Future<bool> requestElevationAndExit() async {
    if (!Platform.isWindows) return true;
    try {
      final exePath = Platform.resolvedExecutable;
      // Start-Process -Verb RunAs يعرض نافذة UAC
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Start-Process -FilePath "$exePath" -Verb RunAs',
        ],
      ).timeout(const Duration(seconds: 30));

      if (r.exitCode == 0) {
        // نجح: اخرج من النسخة غير المرفوعة
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
// main()
// =============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ على Windows: ارفع الصلاحيات قبل أي شيء
  if (Platform.isWindows) {
    final admin = await WindowsElevation.isAdmin();
    if (!admin) {
      // نطلب UAC مباشرة
      final elevated = await WindowsElevation.requestElevationAndExit();
      if (!elevated) {
        runApp(const _ElevationRequiredApp());
        return;
      }
      return; // لن نصل هنا فعلياً (exit)
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
// شاشة: صلاحيات مطلوبة (إن رُفض UAC أو فشل)
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
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
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
                    final ok = await WindowsElevation.requestElevationAndExit();
                    if (!ok) {
                      // UAC رُفض — لا شيء نفعله
                    }
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

// =============================================================================
// شاشة خطأ بدء التشغيل
// =============================================================================

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
