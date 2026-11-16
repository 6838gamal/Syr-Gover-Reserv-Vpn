import 'package:shared_preferences/shared_preferences.dart';

class SessionPersister {
  static const _kSince = 'vpn.connected_since_ms';
  static const _kConfig = 'vpn.active_config_name';

  Future<void> save({
    required DateTime since,
    required String configName,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSince, since.millisecondsSinceEpoch);
    await p.setString(_kConfig, configName);
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSince);
    await p.remove(_kConfig);
  }

  Future<({DateTime since, String configName})?> load() async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_kSince);
    final name = p.getString(_kConfig);
    if (ms == null || name == null) return null;
    return (
      since: DateTime.fromMillisecondsSinceEpoch(ms),
      configName: name as String, // ← صريح لتجنب dynamic
    );
  }
}
