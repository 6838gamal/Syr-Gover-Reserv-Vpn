import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

/// جسر VPN لسطح المكتب (Windows / Linux / macOS)
/// يعتمد على أدوات WireGuard النظامية (wireguard.exe أو wg-quick).
///
/// ملاحظات مهمة:
/// - لا نعتمد على ظهور أيقونة system tray إطلاقاً؛ النجاح يُقاس بوجود
///   خدمة/واجهة النفق فعلياً (sc query على Windows، ip link على Linux).
/// - عند فشل أي أمر، نطبع stderr الحقيقي ونمرره في رسالة الخطأ.
/// - كشف الأدوات يتم عبر requestPermission() برسائل توجيه واضحة.
class VpnBridgeDesktop implements VpnBridge {
  final _controller = StreamController<VpnState>.broadcast();
  VpnState _state = const VpnState();
  Timer? _watchdog;
  String? _confPath;
  String? _tunnelName;
  VpnConfig? _lastConfig;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;
  static const _connectTimeout = Duration(seconds: 15);
  static const _toolCheckTimeout = Duration(seconds: 5);

  bool get _isWindows => Platform.isWindows;
  bool get _isLinux => Platform.isLinux;
  bool get _isMacOS => Platform.isMacOS;

  /// هل نحن على منصة سطح مكتب حقيقية (وليس iOS/Android)؟
  bool get _isRealDesktop => _isWindows || _isLinux || _isMacOS;

  @override
  VpnState get currentState => _state;

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  // ------------------------------------------------------------------
  // init / refreshState
  // ------------------------------------------------------------------

  @override
  Future<void> init() async {
    _emit(const VpnState(status: VpnStatus.disconnected));
  }

  @override
  Future<void> refreshState() async {
    _controller.add(_state);
  }

  // ------------------------------------------------------------------
  // requestPermission — كشف دقيق مع رسائل توجيه
  // ------------------------------------------------------------------

  @override
  Future<bool> requestPermission() async {
    if (!_isRealDesktop) return false;

    if (_isWindows) {
      final ok = await _which('wireguard.exe');
      if (!ok) {
        _emit(const VpnState(
          status: VpnStatus.error,
          errorMessage:
              'WireGuard غير مثبت على هذا الجهاز.\n'
              'حمّله من: https://www.wireguard.com/install/\n'
              'ثم أعد المحاولة.',
        ));
        return false;
      }
      return true;
    }

    // Linux / macOS
    final ok = await _which('wg-quick');
    if (!ok) {
      final hint = _isLinux
          ? 'Ubuntu/Debian: sudo apt install wireguard-tools\n'
              'Fedora: sudo dnf install wireguard-tools\n'
              'Arch: sudo pacman -S wireguard-tools'
          : 'macOS: brew install wireguard-tools';
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage:
            'أداة wg-quick غير مثبتة.\n$hint\nثم أعد المحاولة.',
      ));
      return false;
    }

    // فحص إضافي: هل نستطيع تنفيذ wg-quick بصلاحيات كافية؟
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

  // ------------------------------------------------------------------
  // connect
  // ------------------------------------------------------------------

  @override
  Future<void> connect(VpnConfig config) async {
    if (!_isRealDesktop) {
      _emit(const VpnState(
        status: VpnStatus.error,
        errorMessage: 'VPN غير مدعوم على هذه المنصة',
      ));
      return;
    }

    if (_state.status == VpnStatus.connected ||
        _state.status == VpnStatus.connecting) {
      return;
    }

    _lastConfig = config;
    _tunnelName = config.name;
    _reconnectAttempts = 0;
    _emit(VpnState(
      status: VpnStatus.connecting,
      activeConfigName: config.name,
    ));

    try {
      // 1) تأكد من وجود الأدوات
      final ready = await requestPermission();
      if (!ready) {
        _stopWatchdog();
        return;
      }

      // 2) اكتب ملف الـ conf
      final dir = await getApplicationSupportDirectory();
      _confPath = p.join(dir.path, '${config.name}.conf');
      await File(_confPath!).writeAsString(config.toConf());

      // 3) نفّذ الاتصال حسب المنصة
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
        _startWatchdog(config);
      } else {
        _emit(VpnState(
          status: VpnStatus.error,
          errorMessage: errorDetail ?? 'فشل الاتصال (exit $exitCode)',
          activeConfigName: config.name,
        ));
        _stopWatchdog();
      }
    } catch (e, st) {
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage: 'استثناء: $e',
        activeConfigName: config.name,
      ));
      _stopWatchdog();
      // اطبع stack trace للتشخيص
      stderr.writeln('[VpnBridgeDesktop] connect error: $e\n$st');
    }
  }

  /// يعيد (exitCode, errorDetail)
  Future<(int, String?)> _runWindowsConnect(String confPath) async {
    ProcessResult r;
    try {
      r = await Process.run(
        'wireguard.exe',
        ['/installtunnelservice', confPath],
      ).timeout(_connectTimeout);
    } on TimeoutException {
      return (1, 'انتهت مهلة تثبيت خدمة النفق (15 ثانية).');
    } catch (e) {
      return (1, 'فشل تشغيل wireguard.exe: $e');
    }

    if (r.exitCode != 0) {
      final err = (r.stderr as String?)?.trim();
      return (
        r.exitCode,
        'فشل تثبيت خدمة النفق (exit ${r.exitCode}).'
            '${err != null && err.isNotEmpty ? '\n$err' : ''}\n'
            'تأكد أن التطبيق يعمل كمسؤول (Run as Administrator).'
      );
    }

    final name = p.basenameWithoutExtension(confPath);

    // ننتظر بدء الخدمة فعلياً — لا ننتظر أيقونة system tray إطلاقاً
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await _isTunnelAlive(name)) return (0, null);
    }

    // الخدمة لم تبدأ — اجمع تشخيصاً مفيداً
    final diag = await _diagnoseWindows(name);
    return (
      1,
      'الخدمة WireGuardTunnel\$$name لم تبدأ خلال 10 ثوانٍ.\n$diag'
    );
  }

  Future<(int, String?)> _runLinuxConnect(String confPath, String name) async {
    final attempts = <Future<ProcessResult> Function()>[
      () => Process.run('pkexec', ['wg-quick', 'up', confPath])
          .timeout(_connectTimeout),
      () => Process.run('sudo', ['-n', 'wg-quick', 'up', confPath])
          .timeout(_connectTimeout),
    ];

    final errors = <String>[];

    for (final run in attempts) {
      try {
        final r = await run();
        if (r.exitCode == 0) {
          for (var i = 0; i < 12; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (await _isTunnelAlive(name)) return (0, null);
          }
          errors.add('wg-quick up نجح لكن الواجهة $name لم تظهر.');
        } else {
          final err = (r.stderr as String?)?.trim();
          errors.add('exit ${r.exitCode}${err != null && err.isNotEmpty ? ': $err' : ''}');
        }
      } on TimeoutException {
        errors.add('انتهت المهلة.');
      } catch (e) {
        errors.add(e.toString());
      }
    }

    final hint =
        'جرّب:\n'
        '• sudo apt install wireguard-tools\n'
        '• أو اسمح بالتنفيذ بلا كلمة مرور عبر sudoers:\n'
        '  youruser ALL=(ALL) NOPASSWD: /usr/bin/wg-quick\n'
        '• أو شغّل التطبيق بـ sudo -E.';
    return (
      1,
      'فشل رفع النفق على Linux.\n'
          '${errors.join('\n')}\n\n$hint'
    );
  }

  Future<(int, String?)> _runMacConnect(String confPath, String name) async {
    try {
      final r = await Process.run(
        'sudo',
        ['-n', 'wg-quick', 'up', confPath],
      ).timeout(_connectTimeout);

      if (r.exitCode != 0) {
        final err = (r.stderr as String?)?.trim();
        return (
          r.exitCode,
          'فشل wg-quick على macOS (exit ${r.exitCode}).'
              '${err != null && err.isNotEmpty ? '\n$err' : ''}\n'
              'أضف سطر sudoers لـ wg-quick، أو شغّل التطبيق بـ sudo.'
        );
      }

      for (var i = 0; i < 12; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _isTunnelAlive(name)) return (0, null);
      }
      return (1, 'wg-quick نجح لكن الواجهة $name لم تظهر خلال 6 ثوانٍ.');
    } on TimeoutException {
      return (1, 'انتهت مهلة wg-quick على macOS.');
    } catch (e) {
      return (1, 'استثناء macOS: $e');
    }
  }

  // ------------------------------------------------------------------
  // Watchdog
  // ------------------------------------------------------------------

  void _startWatchdog(VpnConfig config) {
    _stopWatchdog();
    _reconnectAttempts = 0;
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
          errorMessage: 'فشل إعادة الاتصال بعد $_maxReconnectAttempts محاولات',
          activeConfigName: config.name,
        ));
        return;
      }

      _emit(VpnState(
        status: VpnStatus.connecting,
        activeConfigName: config.name,
      ));
      await _forceDown(config.name);

      // تراجع أسي: 2, 4, 8, 16, 32 ثانية
      final delaySec = 1 << _reconnectAttempts;
      await Future.delayed(Duration(seconds: delaySec.clamp(2, 30)));
      await connect(config);
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  // ------------------------------------------------------------------
  // فحص وجود النفق — بدون أي اعتماد على system tray
  // ------------------------------------------------------------------

  Future<bool> _isTunnelAlive(String name) async {
    try {
      if (_isWindows) {
        final r = await Process.run(
          'sc',
          ['query', 'WireGuardTunnel\$$name'],
        ).timeout(const Duration(seconds: 5));
        final out = r.stdout.toString().toUpperCase();
        return r.exitCode == 0 && out.contains('RUNNING');
      }

      // Linux / macOS: تحقق من واجهة الشبكة
      final r = await Process.run('ip', ['link', 'show', name])
          .timeout(const Duration(seconds: 5));
      if (r.exitCode == 0) return true;

      // macOS قد يستخدم ifconfig
      if (_isMacOS) {
        final r2 = await Process.run('ifconfig', [name])
            .timeout(const Duration(seconds: 5));
        return r2.exitCode == 0;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<String> _diagnoseWindows(String name) async {
    final buf = StringBuffer();
    try {
      final q = await Process.run(
        'sc',
        ['query', 'WireGuardTunnel\$$name'],
      ).timeout(const Duration(seconds: 5));
      buf.writeln('sc query:');
      buf.writeln(q.stdout);
      if ((q.stderr as String).isNotEmpty) buf.writeln(q.stderr);
    } catch (_) {}

    try {
      final q = await Process.run(
        'sc',
        ['queryex', 'WireGuardTunnel\$$name'],
      ).timeout(const Duration(seconds: 5));
      buf.writeln('sc queryex:');
      buf.writeln(q.stdout);
    } catch (_) {}

    buf.writeln('افتح services.msc وتحقق من WireGuardTunnel\$$name.');
    buf.writeln('وراجع eventvwr → Windows Logs → System.');
    return buf.toString();
  }

  Future<void> _forceDown(String name) async {
    try {
      if (_isWindows) {
        await Process.run(
          'wireguard.exe',
          ['/uninstalltunnelservice', name],
        ).timeout(const Duration(seconds: 10));
      } else if (_confPath != null) {
        final attempts = <Future<ProcessResult> Function()>[
          () => Process.run('pkexec', ['wg-quick', 'down', _confPath!])
              .timeout(const Duration(seconds: 10)),
          () => Process.run('sudo', ['-n', 'wg-quick', 'down', _confPath!])
              .timeout(const Duration(seconds: 10)),
        ];
        for (final run in attempts) {
          try {
            final r = await run();
            if (r.exitCode == 0) break;
          } catch (_) {}
        }
      }
    } catch (e) {
      stderr.writeln('[VpnBridgeDesktop] _forceDown error: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    _stopWatchdog();
    _emit(VpnState(
      status: VpnStatus.disconnecting,
      activeConfigName: _state.activeConfigName,
    ));
    try {
      await _forceDown(_state.activeConfigName ?? '');
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

  @override
  Future<void> kick() async {
    if (!_isRealDesktop) return;
    final cfg = _lastConfig;
    if (cfg == null) return;
    if (_state.status != VpnStatus.connected) return;

    _emit(VpnState(
      status: VpnStatus.connecting,
      activeConfigName: cfg.name,
    ));
    await _forceDown(cfg.name);
    await Future.delayed(const Duration(seconds: 1));
    await connect(cfg);
  }

  @override
  Future<bool> isConnected() async {
    if (!_isRealDesktop) return false;
    if (_state.status != VpnStatus.connected) return false;
    final name = _tunnelName;
    if (name == null) return false;
    return await _isTunnelAlive(name);
  }

  @override
  Future<void> onNetworkChanged() async => kick();

  // ------------------------------------------------------------------
  // دوال Android-specific — stubs لسطح المكتب
  // ------------------------------------------------------------------

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

  // ------------------------------------------------------------------
  // دوال مساعدة
  // ------------------------------------------------------------------

  /// فحص وجود أمر في PATH (بديل which/where موحّد)
  Future<bool> _which(String cmd) async {
    try {
      if (_isWindows) {
        final r = await Process.run('where', [cmd])
            .timeout(_toolCheckTimeout);
        return r.exitCode == 0;
      }
      final r = await Process.run('which', [cmd])
          .timeout(_toolCheckTimeout);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  void _emit(VpnState s) {
    _state = s;
    _controller.add(s);
  }

  @override
  void dispose() {
    _stopWatchdog();
    _controller.close();
  }
}
