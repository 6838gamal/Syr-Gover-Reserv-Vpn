class VpnConfig {
  final String name;
  final String privateKey;
  final String address;
  final String dns;
  final int mtu;
  final String peerPublicKey;
  final String endpoint;        // host:port (يُفضّل DNS name)
  final String allowedIps;
  final int persistentKeepalive;
  final String? path;           // مسار الملف (Desktop فقط)

  VpnConfig({
    required this.name,
    required this.privateKey,
    required this.address,
    required this.dns,
    required this.mtu,
    required this.peerPublicKey,
    required this.endpoint,
    required this.allowedIps,
    required this.persistentKeepalive,
    this.path,
  });

  // ------------------------------------------------------------------
  // من ملف .conf
  // ------------------------------------------------------------------

  /// يحلل ملف .conf بصيغة wg-quick
  factory VpnConfig.fromConf(String content, {String name = 'imported'}) {
    String? privateKey, address, dns, peerPublic, endpoint, allowedIps;
    int mtu = 1280, keepalive = 25;
    bool inPeer = false;

    for (var raw in content.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('[')) {
        inPeer = line.toLowerCase() == '[peer]';
        continue;
      }
      final idx = line.indexOf('=');
      if (idx == -1) continue;
      final k = line.substring(0, idx).trim().toLowerCase();
      final v = line.substring(idx + 1).trim();

      if (!inPeer) {
        switch (k) {
          case 'privatekey':
            privateKey = v;
            break;
          case 'address':
            address = v.split(',').first.trim();
            break;
          case 'dns':
            dns = v.split(',').first.trim();
            break;
          case 'mtu':
            mtu = int.tryParse(v) ?? 1280;
            break;
        }
      } else {
        switch (k) {
          case 'publickey':
            peerPublic = v;
            break;
          case 'endpoint':
            endpoint = v;
            break;
          case 'allowedips':
            allowedIps = v;
            break;
          case 'persistentkeepalive':
            keepalive = int.tryParse(v) ?? 25;
            break;
        }
      }
    }

    if (privateKey == null || peerPublic == null || endpoint == null) {
      throw const FormatException('ملف .conf غير صالح');
    }
    return VpnConfig(
      name: name,
      privateKey: privateKey,
      address: address ?? '10.0.0.2/32',
      dns: dns ?? '1.1.1.1',
      mtu: mtu,
      peerPublicKey: peerPublic,
      endpoint: endpoint,
      allowedIps: allowedIps ?? '0.0.0.0/0, ::/0',
      persistentKeepalive: keepalive,
    );
  }

  // ------------------------------------------------------------------
  // JSON (flutter_secure_storage)
  // ------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'name': name,
        'privateKey': privateKey,
        'address': address,
        'dns': dns,
        'mtu': mtu,
        'peerPublicKey': peerPublicKey,
        'endpoint': endpoint,
        'allowedIps': allowedIps,
        'persistentKeepalive': persistentKeepalive,
        if (path != null) 'path': path,
      };

  factory VpnConfig.fromJson(Map<String, dynamic> j) => VpnConfig(
        name: j['name'] as String,
        privateKey: j['privateKey'] as String,
        address: j['address'] as String,
        dns: j['dns'] as String,
        mtu: _asInt(j['mtu']) ?? 1280,
        peerPublicKey: j['peerPublicKey'] as String,
        endpoint: j['endpoint'] as String,
        allowedIps: j['allowedIps'] as String,
        persistentKeepalive: _asInt(j['persistentKeepalive']) ?? 25,
        path: j['path'] as String?,
      );

  /// ✅ alias مطلوب بواسطة VpnBridgeDesktop.init()
  /// حيث getLastConfig() يعيد ناتج toJson() (وليس toMap()).
  /// مفاتيح toJson() هي: name, privateKey, address, dns, mtu,
  /// peerPublicKey, endpoint, allowedIps, persistentKeepalive, [path].
  factory VpnConfig.fromMap(Map<String, dynamic> map) =>
      VpnConfig.fromJson(map);

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  // ------------------------------------------------------------------
  // toMap (لإرسالها عبر MethodChannel إلى Kotlin)
  // ------------------------------------------------------------------

  /// المفاتيح هنا **يجب** أن تطابق ما يتوقعه `MyVpnService.buildConfig`.
  ///
  /// ⚠️ لا تحذف '=' من المفاتيح — مفاتيح WireGuard هي Base64
  /// وقد تنتهي بـ '=' (padding). حذفها يجعلها غير صالحة.
  Map<String, dynamic> toMap() => {
        'configName': name,
        'privateKey': privateKey.trim(),
        'address': address.trim(),
        'dns': dns.trim(),
        'mtu': mtu,
        'peerPublicKey': peerPublicKey.trim(),
        'endpoint': endpoint.trim(),
        'allowedIps': _normalizeAllowedIps(allowedIps),
        'persistentKeepalive': persistentKeepalive,
      };

  /// ينظف allowedIps: يفصل بـ ',' ويضيف مسافة بعد كل فاصلة
  static String _normalizeAllowedIps(String raw) {
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(', ');
  }

  // ------------------------------------------------------------------
  // toConf (Desktop)
  // ------------------------------------------------------------------

  /// يحوّل إلى ملف .conf (يستخدمه desktop عند تشغيل wg-quick)
  String toConf() => '''
[Interface]
PrivateKey = $privateKey
Address = $address
DNS = $dns
MTU = $mtu

[Peer]
PublicKey = $peerPublicKey
Endpoint = $endpoint
AllowedIPs = $allowedIps
PersistentKeepalive = $persistentKeepalive
''';
}
