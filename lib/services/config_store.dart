import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/vpn_config.dart';

class ConfigStore {
  static const _key = 'vpn_configs_v1';
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<List<VpnConfig>> loadAll() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => VpnConfig.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAll(List<VpnConfig> configs) async {
    final raw = jsonEncode(configs.map((c) => c.toJson()).toList());
    await _storage.write(key: _key, value: raw);
  }

  Future<void> add(VpnConfig config) async {
    final all = await loadAll();
    all.removeWhere((c) => c.name == config.name);
    all.add(config);
    await saveAll(all);
  }

  Future<void> remove(String name) async {
    final all = await loadAll();
    all.removeWhere((c) => c.name == name);
    await saveAll(all);
  }
}
