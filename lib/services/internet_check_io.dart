// internet_check_io.dart
import 'dart:io';

/// فحص سريع وموثوق للإنترنت.
///
/// يستخدم `generate_204` من Google (لا يستهلك بيانات، معياري):
/// - استجابة 204 = إنترنت يعمل
/// - أي شيء آخر = لا إنترنت
///
/// timeout إجمالي: 3 ثوانٍ (سريع بما يكفي للـ watchdog كل 20s)
Future<bool> hasInternet() async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..idleTimeout = const Duration(seconds: 2);

    final request = await client
        .getUrl(Uri.parse('https://www.gstatic.com/generate_204'))
        .timeout(const Duration(seconds: 3));

    final response = await request
        .close()
        .timeout(const Duration(seconds: 3));

    // استهلك الجسم (حتى لا يتسرب الاتصال)
    await response.drain<void>().timeout(const Duration(seconds: 2));

    return response.statusCode == 204;
  } catch (_) {
    return false;
  } finally {
    client?.close(force: true);
  }
}
