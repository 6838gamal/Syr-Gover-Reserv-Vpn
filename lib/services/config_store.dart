import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/vpn_config.dart';

class ConfigStore {
  static const _key = 'vpn_configs_v1';
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// تحميل كل الإعدادات. آمن ضد JSON التالف.
  Future<List<VpnConfig>> loadAll() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        debugPrint('ConfigStore: corrupted storage (not a list)');
        return [];
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(VpnConfig.fromJson)
          .toList();
    } catch (e) {
      debugPrint('ConfigStore.loadAll failed: $e');
      return [];
    }
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

  Future<void> clear() async {
    await _storage.delete(key: _key);
  }

  /// بحث بالاسم.
  Future<VpnConfig?> getByName(String name) async {
    final all = await loadAll();
    try {
      return all.firstWhere((c) => c.name == name);
    } catch (_) {
      return null;
    }
  }

  /// أول إعدادات (للاستخدام بعد إعادة التشغيل).
  Future<VpnConfig?> getFirst() async {
    final all = await loadAll();
    return all.isEmpty ? null : all.first;
  }
}
