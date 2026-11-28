import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/vpn_config.dart';

class ConfigStore {
  static const _key = 'vpn_configs_v1';
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> _lock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ------------------------- قراءة -------------------------

  Future<List<VpnConfig>> loadAll() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        debugPrint('ConfigStore: corrupted storage (not a list)');
        return [];
      }
      final result = <VpnConfig>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          try {
            result.add(VpnConfig.fromJson(e));
          } catch (err) {
            debugPrint('ConfigStore: skipping invalid entry: $err');
          }
        }
      }
      return result;
    } catch (e) {
      debugPrint('ConfigStore.loadAll failed: $e');
      return [];
    }
  }

  Future<VpnConfig?> getByName(String name) async {
    final all = await loadAll();
    try {
      return all.firstWhere((c) => c.name == name);
    } catch (_) {
      return null;
    }
  }

  Future<VpnConfig?> getFirst() async {
    final all = await loadAll();
    return all.isEmpty ? null : all.first;
  }

  Future<int> count() async => (await loadAll()).length;

  Future<bool> exists(String name) async =>
      (await loadAll()).any((c) => c.name == name);

  // ------------------------- كتابة -------------------------

  Future<void> saveAll(List<VpnConfig> configs) async {
    final raw = jsonEncode(configs.map((c) => c.toJson()).toList());
    await _storage.write(key: _key, value: raw);
  }

  /// يضيف إعداداً جديداً. إذا كان الاسم موجوداً، **يستبدله**.
  Future<void> add(VpnConfig config) => _synchronized(() async {
        final all = await loadAll();
        all.removeWhere((c) => c.name == config.name);
        all.add(config);
        await saveAll(all);
      });

  Future<void> remove(String name) => _synchronized(() async {
        final all = await loadAll();
        all.removeWhere((c) => c.name == name);
        await saveAll(all);
      });

  /// يحدّث إعداداً موجوداً.
  /// - إذا لم يوجد `originalName` → false
  /// - إذا تغيّر الاسم و`updated.name` موجود مسبقاً → false (تعارض)
  /// - خلاف ذلك → true
  Future<bool> update(String originalName, VpnConfig updated) =>
      _synchronized(() async {
        final all = await loadAll();
        final idx = all.indexWhere((c) => c.name == originalName);
        if (idx < 0) return false;

        // منع تعارض الأسماء عند إعادة التسمية
        if (originalName != updated.name) {
          final conflict = all.any((c) => c.name == updated.name);
          if (conflict) {
            debugPrint(
                'ConfigStore.update: name "${updated.name}" already exists');
            return false;
          }
        }

        all[idx] = updated;
        await saveAll(all);
        return true;
      });

  Future<void> clear() async {
    await _synchronized(() => _storage.delete(key: _key));
  }
}
