import 'dart:async';
import 'package:flutter/services.dart';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

class VpnBridgeAndroid implements VpnBridge {
  static final VpnBridgeAndroid _instance = VpnBridgeAndroid._internal();
  factory VpnBridgeAndroid() => _instance;
  VpnBridgeAndroid._internal();

  static const _channel = MethodChannel('com.example.myvpn/vpn');
  static const _events = EventChannel('com.example.myvpn/vpn_events');

  StreamController<VpnState> _controller =
      StreamController<VpnState>.broadcast();

  VpnState _state = const VpnState();
  StreamSubscription? _eventSub;
  String? _lastKnownConfigName;

  Timer? _kickDebounce;
  DateTime _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _eventThrottle = Duration(milliseconds: 300);
  static const _kickDebounceDuration = Duration(seconds: 10);

  String? _lastNetworkKey;

  bool _permissionRequestInFlight = false;
  bool _initialized = false;
  bool _disposed = false;

  @override
  VpnState get currentState => _state;

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _eventSub = _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (e, st) => _emitError('EventChannel error: $e'),
      cancelOnError: false,
    );
    await refreshState();
  }

  @override
  Future<void> refreshState() async {
    try {
      final snapshot = await _channel.invokeMethod<Map>('getState');
      if (snapshot != null) _onNativeEvent(snapshot, force: true);
      await _fetchPendingError();
    } on PlatformException {
      // تجاهل
    }
  }

  Future<void> _fetchPendingError() async {
    try {
      final err = await _channel.invokeMethod<String>('peekPendingError');
      if (err != null &&
          err.isNotEmpty &&
          _state.status != VpnStatus.connected) {
        _emitError(err);
      }
    } catch (_) {}
  }

  void _onNativeEvent(dynamic event, {bool force = false}) {
    if (event is! Map) return;

    final stateStr = (event['state'] as String?) ??
        (event['status'] as String?) ??
        'disconnected';
    final newStatus = _parseStatus(stateStr);

    final critical = newStatus == VpnStatus.connected ||
        newStatus == VpnStatus.disconnected ||
        newStatus == VpnStatus.error;

    final now = DateTime.now();
    if (!force && !critical && now.difference(_lastEventAt) < _eventThrottle) {
      return;
    }
    _lastEventAt = now;

    final message = (event['message'] as String?) ?? (event['error'] as String?);
    final configName = event['configName'] as String?;

    if (configName != null && configName.isNotEmpty) {
      _lastKnownConfigName = configName;
    }

    final nowConnected = newStatus == VpnStatus.connected;
    final prev = _state;

    _state = VpnState(
      status: newStatus,
      errorMessage: newStatus == VpnStatus.error
          ? (message ?? prev.errorMessage)
          : null,
      activeConfigName: (newStatus == VpnStatus.disconnected)
          ? null
          : (configName ?? _lastKnownConfigName),
      connectedSince: nowConnected ? (prev.connectedSince ?? now) : null,
    );

    if (!_disposed && !_controller.isClosed) {
      _controller.add(_state);
    }
  }

  VpnStatus _parseStatus(String? s) {
    return switch (s) {
      'connecting' => VpnStatus.connecting,
      'connected' => VpnStatus.connected,
      'disconnecting' => VpnStatus.disconnecting,
      'error' => VpnStatus.error,
      _ => VpnStatus.disconnected,
    };
  }

  void _emitError(String msg) {
    _state = VpnState(status: VpnStatus.error, errorMessage: msg);
    if (!_disposed && !_controller.isClosed) {
      _controller.add(_state);
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (_permissionRequestInFlight) return false;
    _permissionRequestInFlight = true;
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'BUSY') return false;
      _emitError('prepare failed: ${e.code} ${e.message}');
      return false;
    } finally {
      _permissionRequestInFlight = false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestNotificationPermission') ??
          true;
    } on PlatformException catch (e) {
      if (e.code == 'BUSY') return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> connect(VpnConfig config) async {
    if (_state.status == VpnStatus.connecting) return;
    if (_state.status == VpnStatus.connected &&
        _state.activeConfigName == config.name) {
      return;
    }
    _lastKnownConfigName = config.name;
    try {
      await _channel.invokeMethod('connect', config.toMap());
    } on PlatformException catch (e) {
      if (e.code == 'NO_NOTIFICATION_PERMISSION') {
        throw VpnException('صلاحية الإشعارات مطلوبة لتشغيل VPN', code: e.code);
      }
      if (e.code == 'NO_PERMISSION') {
        throw VpnException('صلاحية VPN مطلوبة', code: e.code);
      }
      _emitError('connect failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _kickDebounce?.cancel();
    _kickDebounce = null;
    if (_state.status == VpnStatus.disconnected) return;
    try {
      await _channel.invokeMethod('disconnect');
      _lastKnownConfigName = null;
      await _waitForState(VpnStatus.disconnected, const Duration(seconds: 5));
    } on PlatformException catch (e) {
      _emitError('disconnect failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> _waitForState(VpnStatus target, Duration timeout) async {
    if (_state.status == target) return;
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = _controller.stream.listen((s) {
      if (s.status == target && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      _state = VpnState(status: target);
      if (!_disposed && !_controller.isClosed) {
        _controller.add(_state);
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      return await _channel.invokeMethod<bool>('isConnected') ?? false;
    } catch (_) {
      return _state.status == VpnStatus.connected;
    }
  }

  @override
  Future<LinkHealth> probeHealth() async {
    if (_state.status != VpnStatus.connected) return LinkHealth.down;
    try {
      final health = await _channel.invokeMethod<String>('probeHealth');
      return switch (health) {
        'good' => LinkHealth.good,
        'suspect' => LinkHealth.suspect,
        'down' => LinkHealth.down,
        _ => LinkHealth.unknown,
      };
    } on PlatformException {
      return LinkHealth.suspect;
    } catch (_) {
      return LinkHealth.suspect;
    }
  }

  @override
  Future<void> onNetworkChanged({String? networkKey}) async {
    if (_state.status != VpnStatus.connected) return;
    if (networkKey != null && networkKey == _lastNetworkKey) return;
    _lastNetworkKey = networkKey;

    _kickDebounce?.cancel();
    _kickDebounce = Timer(_kickDebounceDuration, () async {
      if (_state.status == VpnStatus.connected) {
        await _invokeKick();
      }
    });
  }

  Future<void> _invokeKick() async {
    try {
      await _channel.invokeMethod('kick');
    } on PlatformException catch (e) {
      _emitError('kick failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<void> setKillSwitch(bool enabled) async {
    try {
      await _channel.invokeMethod('setKillSwitch', {'enabled': enabled});
    } on PlatformException catch (e) {
      _emitError('setKillSwitch failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<bool> isKillSwitchActive() async {
    try {
      return await _channel.invokeMethod<bool>('isKillSwitchActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── Autostart / Always-on ─────────────────────────────────────
  @override
  Future<bool> getAutostart() async {
    try {
      return await _channel.invokeMethod<bool>('getAutostart') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> setAutostart(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutostart', {'enabled': enabled});
    } on PlatformException catch (e) {
      _emitError('setAutostart failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<bool> openAlwaysOnSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAlwaysOnSettings') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async {
    try {
      return await _channel
              .invokeMethod<bool>('openBatteryOptimizationSettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  // ── إضافات ──────────────────────────────────────────────────
  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> getNotificationErrorLog() async {
    try {
      return await _channel.invokeMethod<String>('getNotificationErrorLog') ??
          '';
    } on PlatformException catch (e) {
      return 'فشل قراءة السجل: ${e.message}';
    }
  }

  @override
  Future<bool> clearNotificationErrorLog() async {
    try {
      return await _channel.invokeMethod<bool>('clearNotificationErrorLog') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>?> getLastConfig() async {
    try {
      final v = await _channel.invokeMethod<Map>('getLastConfig');
      return v == null ? null : Map<String, dynamic>.from(v);
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> clearLastConfig() async {
    try {
      await _channel.invokeMethod('clearLastConfig');
    } on PlatformException catch (e) {
      _emitError('clearLastConfig failed: ${e.code} ${e.message}');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _kickDebounce?.cancel();
    _kickDebounce = null;
    _eventSub?.cancel();
    _eventSub = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  Future<void> reset() async {
    _disposed = false;
    _initialized = false;
    _state = const VpnState();
    _lastKnownConfigName = null;
    _lastNetworkKey = null;
    _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
    _kickDebounce?.cancel();
    _kickDebounce = null;
    _eventSub?.cancel();
    _eventSub = null;
    if (_controller.isClosed) {
      _controller = StreamController<VpnState>.broadcast();
    }
  }
}
