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
  Process? _process;
  Timer? _watchdog;
  String? _confPath;

  bool get _isWindows => Platform.isWindows;

  @override
  Future<void> init() async {
    _emit(const VpnState());
  }

  @override
  Future<bool> requestPermission() async {
    if (_isWindows) {
      final r = await Process.run('where', ['wireguard.exe']);
      return r.exitCode == 0;
    }
    final r = await Process.run('which', ['wg-quick']);
    return r.exitCode == 0;
  }

  @override
  Future<void> connect(VpnConfig config) async {
    if (_state.status == VpnStatus.connected ||
        _state.status == VpnStatus.connecting) return;

    _emit(VpnState(
        status: VpnStatus.connecting, activeConfigName: config.name));

    try {
      final dir = await getApplicationSupportDirectory();
      _confPath = p.join(dir.path, '${config.name}.conf');
      await File(_confPath!).writeAsString(config.toConf());

      if (_isWindows) {
        _process = await Process.start(
            'wireguard.exe', ['/installtunnelservice', _confPath!]);
      } else {
        _process = await Process.start(
            'sudo', ['wg-quick', 'up', _confPath!]);
      }

      _process!.stdout.transform(utf8.decoder).listen((_) {});
      _process!.stderr.transform(utf8.decoder).listen((err) {
        if (err.trim().isNotEmpty) {
          _emit(VpnState(
            status: VpnStatus.error,
            errorMessage: err.trim(),
            activeConfigName: config.name,
          ));
        }
      });

      final code = await _process!.exitCode;
      if (code == 0) {
        _emit(VpnState(
          status: VpnStatus.connected,
          activeConfigName: config.name,
          connectedSince: DateTime.now(),
        ));
        _startWatchdog(config);
      } else {
        _emit(VpnState(
          status: VpnStatus.error,
          errorMessage: 'فشل التشغيل (exit $code)',
          activeConfigName: config.name,
        ));
      }
    } catch (e) {
      _emit(VpnState(status: VpnStatus.error, errorMessage: e.toString()));
    }
  }

  void _startWatchdog(VpnConfig config) {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_state.status != VpnStatus.connected) return;
      final alive = await _isTunnelAlive(config.name);
      if (!alive) {
        _emit(VpnState(
            status: VpnStatus.connecting,
            activeConfigName: config.name));
        await _forceDown(config.name);
        await Future.delayed(const Duration(seconds: 2));
        await connect(config);
      }
    });
  }

  Future<bool> _isTunnelAlive(String name) async {
    if (_isWindows) {
      final r = await Process.run(
          'sc', ['query', 'WireGuardTunnel\$$name']);
      return r.stdout.toString().contains('RUNNING');
    }
    final r = await Process.run('ip', ['link', 'show', name]);
    return r.exitCode == 0;
  }

  Future<void> _forceDown(String name) async {
    try {
      if (_isWindows) {
        await Process.run(
            'wireguard.exe', ['/uninstalltunnelservice', name]);
      } else if (_confPath != null) {
        await Process.run('sudo', ['wg-quick', 'down', _confPath!]);
      }
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    _watchdog?.cancel();
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
      _emit(const VpnState());
    }
  }

  @override
  Future<void> onNetworkChanged() async {
    if (_state.status != VpnStatus.connected) return;
    // PersistentKeepalive في الإعدادات يتكفل بالاتصال
  }

  void _emit(VpnState s) {
    _state = s;
    _controller.add(s);
  }

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  @override
  void dispose() {
    _watchdog?.cancel();
    _controller.close();
  }
}
