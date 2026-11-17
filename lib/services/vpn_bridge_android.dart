import 'dart:async';

import 'package:flutter/services.dart';

import '../models/vpn_config.dart';
import '../models/vpn_state.dart';
import 'vpn_bridge.dart';

class VpnBridgeAndroid implements VpnBridge {
  static const _channel = MethodChannel('com.example.myvpn/vpn');
  static const _events = EventChannel('com.example.myvpn/vpn_events');

  final _controller = StreamController<VpnState>.broadcast();
  VpnState _state = const VpnState();
  StreamSubscription? _eventSub;

  // ✅ ذاكرة تخزين مؤقتة لاسم الإعدادات لضمان عدم ضياعه
  String? _lastKnownConfigName;

  @override
  VpnState get currentState => _state;

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  // ------------------------------------------------------------------
  // init
  // ------------------------------------------------------------------

  @override
  Future<void> init() async {
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
      if (snapshot != null) _onNativeEvent(snapshot);
    } on PlatformException {
      // تجاهل
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    
    final stateStr = (event['state'] as String?) ?? (event['status'] as String?) ?? 'disconnected';
    final message = (event['message'] as String?) ?? (event['error'] as String?);
    final configName = event['configName'] as String?;

    final status = _parseStatus(stateStr);
    
    // ✅ إذا وصلنا اسم جديد، احفظه
    if (configName != null && configName.isNotEmpty) {
      _lastKnownConfigName = configName;
    }

    final nowConnected = status == VpnStatus.connected;
    final prev = _state;

    _state = VpnState(
      status: status,
      errorMessage: status == VpnStatus.error ? (message ?? prev.errorMessage) : null,
      // ✅ استخدم الاسم الجديد أو المحفوظ مسبقاً
      activeConfigName: (status == VpnStatus.disconnected) 
          ? null 
          : (configName ?? _lastKnownConfigName),
      connectedSince: nowConnected
          ? (prev.connectedSince ?? DateTime.now())
          : null,
    );
    
    _controller.add(_state);
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
    _controller.add(_state);
  }

  // ------------------------------------------------------------------
  // VpnBridge contract
  // ------------------------------------------------------------------

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on PlatformException catch (e) {
      _emitError('prepare failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> connect(VpnConfig config) async {
    // ✅ حفظ الاسم فوراً قبل الإرسال لضمان عدم ضياعه
    _lastKnownConfigName = config.name;
    try {
      await _channel.invokeMethod('connect', config.toMap());
    } on PlatformException catch (e) {
      _emitError('connect failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
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
  Future<void> onNetworkChanged() async => kick();

  // ------------------------------------------------------------------
  // دوال Android-specific
  // ------------------------------------------------------------------

  Future<bool> isAutostartEnabled() async {
    final v = await _channel.invokeMethod<bool>('getAutostart');
    return v ?? false;
  }

  Future<void> setAutostart(bool enabled) async {
    await _channel.invokeMethod('setAutostart', {'enabled': enabled});
  }

  Future<bool> openAlwaysOnSettings() async {
    final v = await _channel.invokeMethod<bool>('openAlwaysOnSettings');
    return v ?? false;
  }

  Future<bool> requestBatteryOptimizationExemption() async {
    final v = await _channel.invokeMethod<bool>('openBatteryOptimizationSettings');
    return v ?? false;
  }

  // ------------------------------------------------------------------
  // dispose
  // ------------------------------------------------------------------

  @override
  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}
