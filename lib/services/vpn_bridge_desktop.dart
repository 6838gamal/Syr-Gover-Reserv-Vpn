import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';
import '../models/link_health.dart'; 

/// جسر VPN لسطح المكتب (Windows / Linux / macOS)
class VpnBridgeDesktop implements VpnBridge {
  static final VpnBridgeDesktop _instance = VpnBridgeDesktop._internal();
  factory VpnBridgeDesktop() => _instance;
  VpnBridgeDesktop._internal();

  StreamController<VpnState> _controller =
      StreamController<VpnState>.broadcast();

  VpnState _state = const VpnState();
  Timer? _watchdog;
  Timer? _kickDebounce;
  String? _confPath;
  String? _tunnelName;
  VpnConfig? _lastConfig;
  int _reconnectAttempts = 0;
  bool _initialized = false;
  bool _disposed = false;

  static const _maxReconnectAttempts = 5;
  static const _connectTimeout = Duration(seconds: 15);
  static const _toolCheckTimeout = Duration(seconds: 5);
  static const _kickDebounceDuration = Duration(seconds: 3);

  bool get _isWindows => Platform.isWindows;
  bool get _isLinux => Platform.isLinux;
  bool get _isMacOS => Platform.isMacOS;
  bool get _isRealDesktop => _isWindows || _isLinux || _isMacOS;

  @override
  VpnState get currentState => _state;

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  // ==================================================================
  // init / refreshState
  // ==================================================================

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (!_isRealDesktop) {
      _emit(const VpnState(status: VpnStatus.disconnected));
      return;
    }

    try {
      final saved = await getLastConfig();
      if (saved != null) {
        final cfg = VpnConfig.fromMap(saved);
        if (await _isTunnelAlive(cfg.name)) {
          _lastConfig = cfg;
          _tunnelName = cfg.name;
          _confPath = p.join(
            (await getApplicationSupportDirectory()).path,
            '${cfg.name}.conf',
          );
          _emit(VpnState(
            status: VpnStatus.connected,
            activeConfigName: cfg.name,
            connectedSince: DateTime.now(),
          ));
          _startWatchdog(cfg);
          return;
        }
      }
    } catch (_) {}

    _emit(const VpnState(status: VpnStatus.disconnected));
  }

  @override
  Future<void> refreshState() async {
    if (!_isRealDesktop) {
      _emit(const VpnState(status: VpnStatus.disconnected));
      return;
    }
    final name = _tunnelName;
    if (name == null) {
      _emit(const VpnState(status: VpnStatus.disconnected));
      return;
    }
    final alive = await _isTunnelAlive(name);
    _emit(VpnState(
      status: alive ? VpnStatus.connected : VpnStatus.disconnected,
      activeConfigName: alive ? name : null,
      connectedSince: alive ? (_state.connectedSince ?? DateTime.now()) : null,
    ));
  }

  // ==================================================================
  // requestPermission
  // ==================================================================

  @override
  Future<bool> requestPermission() async {
    if (!_isRealDesktop) return false;

    if (_isWindows) {
      final exe = await _findWireGuardWindows();
      if (exe == null) {
        _emit(const VpnState(
          status: VpnStatus.error,
          errorMessage: 'WireGuard غير مثبت على هذا الجهاز.\n'
              'حمّله من: https://www.wireguard.com/install/\n'
              'ثم أعد المحاولة.',
        ));
        return false;
      }
      return true;
    }

    final ok = await _which('wg-quick');
    if (!ok) {
      final hint = _isLinux
          ? 'Ubuntu/Debian: sudo apt install wireguard-tools\n'
              'Fedora: sudo dnf install wireguard-tools\n'
              'Arch: sudo pacman -S wireguard-tools'
          : 'macOS: brew install wireguard-tools';
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage: 'أداة wg-quick غير مثبتة.\n$hint\nثم أعد المحاولة.',
      ));
      return false;
    }

    if (_isLinux) {
      final canPkexec = await _which('pkexec');
      final canSudo = await _which('sudo');
      if (!canPkexec && !canSudo) {
        _emit(const VpnState(
          status: VpnStatus.error,
          errorMessage:
              'لا يوجد pkexec ولا sudo. شغّل التطبيق بصلاحيات إدارية أو ثبّت polkit.',
        ));
        return false;
      }
    } else if (_isMacOS) {
      final canSudo = await _which('sudo');
      if (!canSudo) {
        _emit(const VpnState(
          status: VpnStatus.error,
          errorMessage: 'sudo غير متاح. شغّل التطبيق من طرفية بصلاحيات إدارية.',
        ));
        return false;
      }
    }

    return true;
  }

  @override
  Future<bool> requestNotificationPermission() async => true;

  // ==================================================================
  // connect
  // ==================================================================

  @override
  Future<void> connect(VpnConfig config) => _doConnect(config);

  Future<void> _doConnect(
    VpnConfig config, {
    bool fromWatchdog = false,
  }) async {
    if (!_isRealDesktop) {
      final msg = 'VPN غير مدعوم على هذه المنصة';
      _emit(VpnState(status: VpnStatus.error, errorMessage: msg));
      throw VpnException(msg, code: 'UNSUPPORTED_PLATFORM');
    }

    if (_state.status == VpnStatus.connected ||
        _state.status == VpnStatus.connecting) {
      return;
    }

    _lastConfig = config;
    _tunnelName = config.name;
    if (!fromWatchdog) _reconnectAttempts = 0;

    _emit(VpnState(
      status: VpnStatus.connecting,
      activeConfigName: config.name,
    ));

    try {
      final ready = await requestPermission();
      if (!ready) {
        _stopWatchdog();
        throw VpnException(
          _state.errorMessage ?? 'الأدوات المطلوبة غير متوفرة',
          code: 'TOOLS_MISSING',
        );
      }

      final dir = await getApplicationSupportDirectory();
      _confPath = p.join(dir.path, '${config.name}.conf');
      final confFile = File(_confPath!);
      if (!await confFile.exists() ||
          (await confFile.readAsString()) != config.toConf()) {
        await confFile.writeAsString(config.toConf());
      }

      int exitCode;
      String? errorDetail;
      if (_isWindows) {
        final r = await _runWindowsConnect(_confPath!);
        exitCode = r.$1;
        errorDetail = r.$2;
      } else if (_isLinux) {
        final r = await _runLinuxConnect(_confPath!, config.name);
        exitCode = r.$1;
        errorDetail = r.$2;
      } else {
        final r = await _runMacConnect(_confPath!, config.name);
        exitCode = r.$1;
        errorDetail = r.$2;
      }

      if (exitCode == 0) {
        _emit(VpnState(
          status: VpnStatus.connected,
          activeConfigName: config.name,
          connectedSince: DateTime.now(),
        ));
        if (!fromWatchdog) _startWatchdog(config);
      } else {
        final msg = errorDetail ?? 'فشل الاتصال (exit $exitCode)';
        _emit(VpnState(
          status: VpnStatus.error,
          errorMessage: msg,
          activeConfigName: config.name,
        ));
        _stopWatchdog();
        throw VpnException(msg, code: 'CONNECT_FAILED');
      }
    } on VpnException {
      rethrow;
    } catch (e, st) {
      final msg = 'استثناء: $e';
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage: msg,
        activeConfigName: config.name,
      ));
      _stopWatchdog();
      stderr.writeln('[VpnBridgeDesktop] connect error: $e\n$st');
      throw VpnException(msg, code: 'CONNECT_EXCEPTION');
    }
  }

  // ==================================================================
  // _runSafe
  // ==================================================================

  Future<(int, String, String)?> _runSafe(
    String exe,
    List<String> args,
    Duration timeout,
  ) async {
    Process? proc;
    try {
      proc = await Process.start(exe, args);
    } catch (e) {
      return (1, '', 'فشل تشغيل $exe: $e');
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final outSub =
        proc.stdout.transform(SystemEncoding().decoder).listen(stdoutBuf.write);
    final errSub =
        proc.stderr.transform(SystemEncoding().decoder).listen(stderrBuf.write);

    try {
      final code = await proc.exitCode.timeout(timeout);
      await Future.wait([outSub.cancel(), errSub.cancel()]);
      return (code, stdoutBuf.toString(), stderrBuf.toString());
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      await outSub.cancel();
      await errSub.cancel();
      return null;
    }
  }

  // ==================================================================
  // Windows
  // ==================================================================

  Future<String?> _findWireGuardWindows() async {
    try {
      final r = await Process.run('where', ['wireguard.exe'])
          .timeout(_toolCheckTimeout);
      if (r.exitCode == 0) {
        final first = (r.stdout as String).split('\n').first.trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}

    const candidates = [
      r'C:\Program Files\WireGuard\wireguard.exe',
      r'C:\Program Files (x86)\WireGuard\wireguard.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  Future<(int, String?)> _runWindowsConnect(String confPath) async {
    final exe = await _findWireGuardWindows();
    if (exe == null) {
      return (1, 'wireguard.exe غير موجود. أعد تثبيت WireGuard.');
    }

    final r = await _runSafe(
      exe,
      ['/installtunnelservice', confPath],
      _connectTimeout,
    );

    if (r == null) {
      return (1, 'انتهت مهلة تثبيت خدمة النفق (15 ثانية).');
    }

    final (code, _, stderrStr) = r;
    if (code != 0) {
      final err = stderrStr.trim();
      return (
        code,
        'فشل تثبيت خدمة النفق (exit $code).'
            '${err.isNotEmpty ? '\n$err' : ''}\n'
            'تأكد أن التطبيق يعمل كمسؤول (Run as Administrator).'
      );
    }

    final name = p.basenameWithoutExtension(confPath);

    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await _isTunnelAlive(name)) return (0, null);
    }

    final diag = await _diagnoseWindows(name);
    return (1, 'الخدمة WireGuardTunnel\$$name لم تبدأ خلال 10 ثوانٍ.\n$diag');
  }

  Future<String> _diagnoseWindows(String name) async {
    final buf = StringBuffer();
    try {
      final q = await Process.run('sc', ['query', 'WireGuardTunnel\$$name'])
          .timeout(const Duration(seconds: 5));
      buf.writeln('sc query:');
      buf.writeln(q.stdout);
      if ((q.stderr as String).isNotEmpty) buf.writeln(q.stderr);
    } catch (_) {}

    try {
      final q = await Process.run('sc', ['queryex', 'WireGuardTunnel\$$name'])
          .timeout(const Duration(seconds: 5));
      buf.writeln('sc queryex:');
      buf.writeln(q.stdout);
    } catch (_) {}

    buf.writeln('افتح services.msc وتحقق من WireGuardTunnel\$$name.');
    buf.writeln('وراجع eventvwr → Windows Logs → System.');
    return buf.toString();
  }

  // ==================================================================
  // Linux / macOS
  // ==================================================================

  Future<(int, String?)> _runLinuxConnect(String confPath, String name) async {
    final attempts = <Future<(int, String, String)?> Function()>[
      () => _runSafe('pkexec', ['wg-quick', 'up', confPath], _connectTimeout),
      () =>
          _runSafe('sudo', ['-n', 'wg-quick', 'up', confPath], _connectTimeout),
    ];

    final errors = <String>[];

    for (final run in attempts) {
      try {
        final r = await run();
        if (r == null) {
          errors.add('انتهت المهلة.');
          continue;
        }
        final (code, _, err) = r;
        if (code == 0) {
          for (var i = 0; i < 12; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (await _isTunnelAlive(name)) return (0, null);
          }
          errors.add('wg-quick up نجح لكن الواجهة $name لم تظهر.');
        } else {
          errors.add(
              'exit $code${err.trim().isNotEmpty ? ': ${err.trim()}' : ''}');
        }
      } catch (e) {
        errors.add(e.toString());
      }
    }

    final hint = 'جرّب:\n'
        '• sudo apt install wireguard-tools\n'
        '• أو اسمح بالتنفيذ بلا كلمة مرور عبر sudoers:\n'
        '  youruser ALL=(ALL) NOPASSWD: /usr/bin/wg-quick\n'
        '• أو شغّل التطبيق بـ sudo -E.';
    return (1, 'فشل رفع النفق على Linux.\n${errors.join('\n')}\n\n$hint');
  }

  Future<(int, String?)> _runMacConnect(String confPath, String name) async {
    final r = await _runSafe(
      'sudo',
      ['-n', 'wg-quick', 'up', confPath],
      _connectTimeout,
    );

    if (r == null) {
      return (1, 'انتهت مهلة wg-quick على macOS.');
    }

    final (code, _, err) = r;
    if (code != 0) {
      return (
        code,
        'فشل wg-quick على macOS (exit $code).'
            '${err.trim().isNotEmpty ? '\n${err.trim()}' : ''}\n'
            'أضف سطر sudoers لـ wg-quick، أو شغّل التطبيق بـ sudo.'
      );
    }

    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await _isTunnelAlive(name)) return (0, null);
    }
    return (1, 'wg-quick نجح لكن الواجهة $name لم تظهر خلال 6 ثوانٍ.');
  }

  // ==================================================================
  // Watchdog
  // ==================================================================

  void _startWatchdog(VpnConfig config) {
    _stopWatchdog();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_state.status != VpnStatus.connected) {
        if (_state.status == VpnStatus.error) _stopWatchdog();
        return;
      }

      final alive = await _isTunnelAlive(config.name);
      if (alive) {
        _reconnectAttempts = 0;
        return;
      }

      _reconnectAttempts++;
      if (_reconnectAttempts > _maxReconnectAttempts) {
        _stopWatchdog();
        _emit(VpnState(
          status: VpnStatus.error,
          errorMessage:
              'فشل إعادة الاتصال بعد $_maxReconnectAttempts محاولات',
          activeConfigName: config.name,
        ));
        return;
      }

      _emit(VpnState(
        status: VpnStatus.connecting,
        activeConfigName: config.name,
      ));
      await _forceDown(config.name);

      final delaySec = (1 << _reconnectAttempts).clamp(2, 30);
      await Future.delayed(Duration(seconds: delaySec));

      try {
        await _doConnect(config, fromWatchdog: true);
      } catch (_) {}
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  // ==================================================================
  // فحص وجود النفق
  // ==================================================================

  Future<bool> _isTunnelAlive(String name) async {
    try {
      if (_isWindows) {
        final r = await Process.run('sc', ['query', 'WireGuardTunnel\$$name'])
            .timeout(const Duration(seconds: 5));
        final out = r.stdout.toString().toUpperCase();
        return r.exitCode == 0 && out.contains('RUNNING');
      }

      const ipCandidates = [
        '/sbin/ip',
        '/usr/sbin/ip',
        '/bin/ip',
        '/usr/bin/ip',
        'ip',
      ];
      for (final exe in ipCandidates) {
        try {
          final r = await Process.run(exe, ['link', 'show', name])
              .timeout(const Duration(seconds: 5));
          if (r.exitCode == 0) return true;
          break;
        } catch (_) {
          continue;
        }
      }

      if (_isMacOS) {
        final r = await Process.run('ifconfig', [name])
            .timeout(const Duration(seconds: 5));
        return r.exitCode == 0;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _forceDown(String name) async {
    try {
      if (_isWindows) {
        final exe = await _findWireGuardWindows();
        if (exe != null) {
          await _runSafe(
            exe,
            ['/uninstalltunnelservice', name],
            const Duration(seconds: 10),
          );
        }
      } else if (_confPath != null) {
        final attempts = <Future<(int, String, String)?> Function()>[
          () => _runSafe('pkexec', ['wg-quick', 'down', _confPath!],
              const Duration(seconds: 10)),
          () => _runSafe('sudo', ['-n', 'wg-quick', 'down', _confPath!],
              const Duration(seconds: 10)),
        ];
        for (final run in attempts) {
          try {
            final r = await run();
            if (r != null && r.$1 == 0) break;
          } catch (_) {}
        }
      }
    } catch (e) {
      stderr.writeln('[VpnBridgeDesktop] _forceDown error: $e');
    }
  }

  // ==================================================================
  // disconnect
  // ==================================================================

  @override
  Future<void> disconnect() async {
    _kickDebounce?.cancel();
    _kickDebounce = null;
    _stopWatchdog();

    final activeName = _state.activeConfigName;
    if (activeName == null && _confPath == null) {
      _emit(const VpnState(status: VpnStatus.disconnected));
      return;
    }

    _emit(VpnState(
      status: VpnStatus.disconnecting,
      activeConfigName: activeName,
    ));

    try {
      await _forceDown(activeName ?? _tunnelName ?? '');
    } finally {
      if (_confPath != null) {
        try {
          await File(_confPath!).delete();
        } catch (_) {}
      }
      _confPath = null;
      _tunnelName = null;
      _lastConfig = null;
      _reconnectAttempts = 0;
      _emit(const VpnState(status: VpnStatus.disconnected));
    }
  }

  // ==================================================================
  // onNetworkChanged + _invokeKick
  // ==================================================================

  @override
  Future<void> onNetworkChanged({String? networkKey}) async {
    if (_state.status != VpnStatus.connected) return;
    await _invokeKick();
  }

  Future<void> _invokeKick() async {
    if (!_isRealDesktop) return;
    final cfg = _lastConfig;
    if (cfg == null || _confPath == null) return;
    if (_state.status != VpnStatus.connected) return;

    _emit(VpnState(
      status: VpnStatus.connecting,
      activeConfigName: cfg.name,
    ));

    await _forceDown(cfg.name);
    await Future.delayed(const Duration(seconds: 1));

    (int, String?) r;
    if (_isWindows) {
      r = await _runWindowsConnect(_confPath!);
    } else if (_isLinux) {
      r = await _runLinuxConnect(_confPath!, cfg.name);
    } else {
      r = await _runMacConnect(_confPath!, cfg.name);
    }

    if (r.$1 == 0) {
      _emit(VpnState(
        status: VpnStatus.connected,
        activeConfigName: cfg.name,
        connectedSince: DateTime.now(),
      ));
    } else {
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage: r.$2 ?? 'فشل إعادة الاتصال',
        activeConfigName: cfg.name,
      ));
      _stopWatchdog();
    }
  }

  // ==================================================================
  // isConnected / probeHealth
  // ==================================================================

  @override
  Future<bool> isConnected() async {
    if (!_isRealDesktop) return false;
    if (_state.status != VpnStatus.connected) return false;
    final name = _tunnelName;
    if (name == null) return false;
    return await _isTunnelAlive(name);
  }

  @override
  Future<LinkHealth> probeHealth() async {
    if (_state.status != VpnStatus.connected) return LinkHealth.down;
    final name = _tunnelName;
    if (name == null) return LinkHealth.down;

    final alive = await _isTunnelAlive(name);
    if (!alive) return LinkHealth.down;

    if (!_isWindows) {
      try {
        final r = await _runSafe(
          'wg',
          ['show', name, 'latest-handshakes'],
          const Duration(seconds: 3),
        );
        if (r != null && r.$1 == 0) {
          final lines = r.$2.trim().split('\n');
          if (lines.isNotEmpty) {
            final parts = lines.first.split('\t');
            if (parts.length >= 2) {
              final ts = int.tryParse(parts[1]);
              if (ts != null && ts > 0) {
                final ageSec =
                    DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
                if (ageSec > 180) return LinkHealth.suspect;
              }
            }
          }
        }
      } catch (_) {}
    }

    return LinkHealth.good;
  }

  // ==================================================================
  // Kill Switch
  // ==================================================================

  @override
  Future<void> setKillSwitch(bool enabled) async {
    stderr.writeln(
      '[VpnBridgeDesktop] setKillSwitch($enabled) — not implemented yet',
    );
  }

  @override
  Future<bool> isKillSwitchActive() async => false;

  // ==================================================================
  // Autostart / Always-on (Desktop — stubs)
  // ==================================================================

  @override
  Future<bool> getAutostart() async => false;

  @override
  Future<void> setAutostart(bool enabled) async {}

  @override
  Future<bool> openAlwaysOnSettings() async => false;

  @override
  Future<bool> requestBatteryOptimizationExemption() async => false;

  // ==================================================================
  // إضافات
  // ==================================================================

  @override
  Future<String> getNotificationErrorLog() async => '';

  @override
  Future<bool> clearNotificationErrorLog() async => false;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<Map<String, dynamic>?> getLastConfig() async {
    if (_lastConfig == null) return null;
    return _lastConfig!.toJson();
  }

  @override
  Future<void> clearLastConfig() async {
    _lastConfig = null;
  }

  // ==================================================================
  // دوال مساعدة
  // ==================================================================

  Future<bool> _which(String cmd) async {
    try {
      if (_isWindows) {
        final r =
            await Process.run('where', [cmd]).timeout(_toolCheckTimeout);
        return r.exitCode == 0;
      }
      final r = await Process.run('which', [cmd]).timeout(_toolCheckTimeout);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  void _emit(VpnState s) {
    if (_state.status == s.status &&
        _state.activeConfigName == s.activeConfigName &&
        _state.errorMessage == s.errorMessage &&
        _state.connectedSince == s.connectedSince) {
      return;
    }
    _state = s;
    if (!_disposed && !_controller.isClosed) {
      _controller.add(s);
    }
  }

  // ==================================================================
  // dispose / reset
  // ==================================================================

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _kickDebounce?.cancel();
    _kickDebounce = null;
    _stopWatchdog();
    if (!_controller.isClosed) _controller.close();
  }

  Future<void> reset() async {
    _disposed = false;
    _initialized = false;
    _state = const VpnState();
    _lastConfig = null;
    _tunnelName = null;
    _confPath = null;
    _reconnectAttempts = 0;
    _stopWatchdog();
    _kickDebounce?.cancel();
    _kickDebounce = null;
    if (_controller.isClosed) {
      _controller = StreamController<VpnState>.broadcast();
    }
  }
}
