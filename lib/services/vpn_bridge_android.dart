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

  @override
  Future<void> init() async {
    _eventSub = _events.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      _state = VpnState(
        status: _parseStatus(map['status'] as String?),
        errorMessage: map['error'] as String?,
        activeConfigName: map['configName'] as String?,
      );
      _controller.add(_state);
    });
  }

  VpnStatus _parseStatus(String? s) {
    switch (s) {
      case 'connecting':
        return VpnStatus.connecting;
      case 'connected':
        return VpnStatus.connected;
      case 'disconnecting':
        return VpnStatus.disconnecting;
      case 'error':
        return VpnStatus.error;
      default:
        return VpnStatus.disconnected;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final ok = await _channel.invokeMethod<bool>('prepare');
    return ok ?? false;
  }

  @override
  Future<void> connect(VpnConfig config) async {
    await _channel.invokeMethod('connect', {
      'privateKey': config.privateKey,
      'address': config.address,
      'dns': config.dns,
      'mtu': config.mtu,
      'peerPublicKey': config.peerPublicKey,
      'endpoint': config.endpoint,
      'allowedIps': config.allowedIps,
      'persistentKeepalive': config.persistentKeepalive,
      'configName': config.name,
    });
  }

  @override
  Future<void> disconnect() => _channel.invokeMethod('disconnect');

  @override
  Future<void> onNetworkChanged() => _channel.invokeMethod('kick');

  @override
  Stream<VpnState> get stateStream => _controller.stream;

  @override
  VpnState get currentState => _state;

  @override
  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}
