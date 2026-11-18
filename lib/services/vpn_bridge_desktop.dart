import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

class VpnBridgeDesktop implements VpnBridge {
  final _controller = StreamController<VpnState>.broadcast();
  VpnState _state = const VpnState();
  Timer? _watchdog;
  String? _confPath;
  String? _tunnelName;
  VpnConfig? _lastConfig;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;

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
  // requestPermission
  // ------------------------------------------------------------------

  @override
  Future<bool> requestPermission() async {
    if (!_isRealDesktop) return false;  // iOS/Android: غير مدعوم
    try {
      if (_isWindows) {
        final r = await Process.run('where', ['wireguard.exe'])
            .timeout(const Duration(seconds: 3));
        return r.exitCode == 0;
      }
      final r = await Process.run('which', ['wg-quick'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
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
      final dir = await getApplicationSupportDirectory();
      _confPath = p.join(dir.path, '${config.name}.conf');
      await File(_confPath!).writeAsString(config.toConf());

      int exitCode;
      if (_isWindows) {
        exitCode = await _runWindowsConnect(_confPath!);
      } else if (_isLinux) {
        exitCode = await _runLinuxConnect(_confPath!, config.name);
      } else {
        exitCode = await _runMacConnect(_confPath!, config.name);
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
          errorMessage: 'فشل الاتصال (exit $exitCode)',
          activeConfigName: config.name,
        ));
        _stopWatchdog();
      }
    } catch (e) {
      _emit(VpnState(
        status: VpnStatus.error,
        errorMessage: e.toString(),
        activeConfigName: config.name,
      ));
      _stopWatchdog();
    }
  }

  Future<int> _runWindowsConnect(String confPath) async {
    final r = await Process.run(
      'wireguard.exe',
      ['/installtunnelservice', confPath],
    ).timeout(const Duration(seconds: 15));
    if (r.exitCode != 0) return r.exitCode;

    final name = p.basenameWithoutExtension(confPath);
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await _isTunnelAlive(name)) return 0;
    }
    return 1;
  }

  Future<int> _runLinuxConnect(String confPath, String name) async {
    final runners = <List<String>>[
      ['pkexec', 'wg-quick', 'up', confPath],
      ['sudo', '-n', 'wg-quick', 'up', confPath],
    ];

    for (final args in runners) {
      try {
        final exe = args.removeAt(0);
        final r = await Process.run(exe, args)
            .timeout(const Duration(seconds: 20));
        if (r.exitCode == 0) {
          for (var i = 0; i < 6; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (await _isTunnelAlive(name)) return 0;
          }
        }
      } catch (_) {}
    }
    return 1;
  }

  Future<int> _runMacConnect(String confPath, String name) async {
    try {
      final r = await Process.run(
        'sudo',
        ['-n', 'wg-quick', 'up', confPath],
      ).timeout(const Duration(seconds: 20));
      if (r.exitCode != 0) return r.exitCode;
      for (var i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _isTunnelAlive(name)) return 0;
      }
    } catch (_) {}
    return 1;
  }

  // ------------------------------------------------------------------
  // Watchdog
  // ------------------------------------------------------------------

  void _startWatchdog(VpnConfig config) {
    _stopWatchdog();
    _reconnectAttempts = 0;
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_state.status != VpnStatus.connected) {
        // الحالة ليست connected — أوقف الـ watchdog
        if (_state.status == VpnStatus.error) _stopWatchdog();
        return;
      }

      final alive = await _isTunnelAlive(config.name);
      if (alive) {
        _reconnectAttempts = 0;
        return;
      }

      // النفق ميت — حاول إعادة الاتصال
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
      await Future.delayed(const Duration(seconds: 2));
      await connect(config);
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  Future<bool> _isTunnelAlive(String name) async {
    try {
      if (_isWindows) {
        final r = await Process.run(
          'sc',
          ['query', 'WireGuardTunnel\$$name'],
        ).timeout(const Duration(seconds: 3));
        return r.stdout.toString().contains('RUNNING');
      }
      final r = await Process.run('ip', ['link', 'show', name])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _forceDown(String name) async {
    try {
      if (_isWindows) {
        await Process.run(
          'wireguard.exe',
          ['/uninstalltunnelservice', name],
        ).timeout(const Duration(seconds: 10));
      } else if (_confPath != null) {
        final runners = <List<String>>[
          ['pkexec', 'wg-quick', 'down', _confPath!],
          ['sudo', '-n', 'wg-quick', 'down', _confPath!],
        ];
        for (final args in runners) {
          try {
            final exe = args.removeAt(0);
            final r = await Process.run(exe, args)
                .timeout(const Duration(seconds: 10));
            if (r.exitCode == 0) break;
          } catch (_) {}
        }
      }
    } catch (_) {}
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
    // على سطح المكتب، نستخدم _lastConfig المحفوظ في الذاكرة
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
