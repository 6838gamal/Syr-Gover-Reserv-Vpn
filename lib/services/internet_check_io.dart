import 'dart:io';

Future<bool> hasInternet() async {
  try {
    final r = await InternetAddress.lookup('1.1.1.1')
        .timeout(const Duration(seconds: 3));
    return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}
