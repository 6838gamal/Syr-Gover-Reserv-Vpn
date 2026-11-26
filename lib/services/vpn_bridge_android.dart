import 'dart:async';
import 'package:flutter/services.dart';
import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart'; // VpnException تُستورد من هنا

class VpnBridgeAndroid implements VpnBridge {
  // ------------------------------------------------------------------
  // Singleton — يمنع إنشاء مستمعين متعددين لنفس EventChannel
  // ------------------------------------------------------------------
  static final VpnBridgeAndroid _instance = VpnBridgeAndroid._internal();
  factory VpnBridgeAndroid() => _instance;
  VpnBridgeAndroid._internal();

  static const _channel = MethodChannel('com.example.myvpn/vpn');
  static const _events = EventChannel('com.example.myvpn/vpn_events');

  final _controller = StreamController<VpnState>.broadcast();
  VpnState _state = const VpnState();
  StreamSubscription? _eventSub;
  String? _lastKnownConfigName;

  // --- حماية من التكرار ---
  Timer? _kickDebounce;
  DateTime _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _eventThrottle = Duration(milliseconds: 300);
  static const _kickDebounceDuration = Duration(seconds: 3);

  bool _initialized = false;
  bool _disposed = false;

  @override
  VpnState get currentState => _state;

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  // ------------------------------------------------------------------
  // init
  // ------------------------------------------------------------------

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
      final err = await _channel.invokeMethod<String>('getPendingError');
      if (err != null && err.isNotEmpty && _state.status != VpnStatus.connected) {
        _emitError(err);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // معالجة الأحداث مع throttle
  // ------------------------------------------------------------------

  void _onNativeEvent(dynamic event, {bool force = false}) {
    if (event is! Map) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastEventAt) < _eventThrottle) return;
    _lastEventAt = now;

    final stateStr =
        (event['state'] as String?) ?? (event['status'] as String?) ?? 'disconnected';
    final message = (event['message'] as String?) ?? (event['error'] as String?);
    final configName = event['configName'] as String?;

    final status = _parseStatus(stateStr);

    if (configName != null && configName.isNotEmpty) {
      _lastKnownConfigName = configName;
    }

    final nowConnected = status == VpnStatus.connected;
    final prev = _state;

    _state = VpnState(
      status: status,
      errorMessage: status == VpnStatus.error ? (message ?? prev.errorMessage) : null,
      activeConfigName: (status == VpnStatus.disconnected)
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

  // ------------------------------------------------------------------
  // VpnBridge contract
  // ------------------------------------------------------------------

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'BUSY') return false;
      _emitError('prepare failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? true;
    } on PlatformException catch (e) {
      if (e.code == 'BUSY') return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> connect(VpnConfig config) async {
    if (_state.status == VpnStatus.connecting ||
        _state.status == VpnStatus.connected) {
      return; // اتصال جارٍ أو قائم بالفعل
    }
    _lastKnownConfigName = config.name;
    try {
      await _channel.invokeMethod('connect', config.toMap());
    } on PlatformException catch (e) {
      if (e.code == 'NO_NOTIFICATION_PERMISSION') {
        throw VpnException(
          'صلاحية الإشعارات مطلوبة لتشغيل VPN',
          code: e.code,
        );
      }
      if (e.code == 'NO_PERMISSION') {
        throw VpnException(
          'صلاحية VPN مطلوبة',
          code: e.code,
        );
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
    } on PlatformException catch (e) {
      _emitError('disconnect failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  @override
  Future<void> kick() async {
    try {
      await _channel.invokeMethod('kick');
    } on PlatformException catch (e) {
      _emitError('kick failed: ${e.code} ${e.message}');
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
  Future<void> onNetworkChanged() async {
    if (_state.status != VpnStatus.connected) return;

    _kickDebounce?.cancel();
    _kickDebounce = Timer(_kickDebounceDuration, () async {
      if (_state.status == VpnStatus.connected) {
        await kick();
      }
    });
  }

  // ------------------------------------------------------------------
  // Autostart
  // ------------------------------------------------------------------

  Future<bool> isAutostartEnabled() async {
    try {
      final v = await _channel.invokeMethod<bool>('getAutostart');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setAutostart(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutostart', {'enabled': enabled});
    } on PlatformException catch (e) {
      _emitError('setAutostart failed: ${e.code} ${e.message}');
    }
  }

  // ------------------------------------------------------------------
  // Always-On VPN
  // ------------------------------------------------------------------

  Future<bool> openAlwaysOnSettings() async {
    try {
      final v = await _channel.invokeMethod<bool>('openAlwaysOnSettings');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Battery Optimization
  // ------------------------------------------------------------------

  Future<bool> requestBatteryOptimizationExemption() async {
    try {
      final v = await _channel.invokeMethod<bool>('openBatteryOptimizationSettings');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final v = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // App Settings
  // ------------------------------------------------------------------

  Future<bool> openAppSettings() async {
    try {
      final v = await _channel.invokeMethod<bool>('openAppSettings');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Notification error log
  // ------------------------------------------------------------------

  Future<String> getNotificationErrorLog() async {
    try {
      final v = await _channel.invokeMethod<String>('getNotificationErrorLog');
      return v ?? '';
    } on PlatformException catch (e) {
      return 'فشل قراءة السجل: ${e.message}';
    }
  }

  Future<bool> clearNotificationErrorLog() async {
    try {
      final v = await _channel.invokeMethod<bool>('clearNotificationErrorLog');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Saved config
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>?> getLastConfig() async {
    try {
      final v = await _channel.invokeMethod<Map>('getLastConfig');
      return v == null ? null : Map<String, dynamic>.from(v);
    } on PlatformException {
      return null;
    }
  }

  Future<void> clearLastConfig() async {
    try {
      await _channel.invokeMethod('clearLastConfig');
    } on PlatformException catch (e) {
      _emitError('clearLastConfig failed: ${e.code} ${e.message}');
    }
  }

  // ------------------------------------------------------------------
  // dispose
  // ------------------------------------------------------------------

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
}
