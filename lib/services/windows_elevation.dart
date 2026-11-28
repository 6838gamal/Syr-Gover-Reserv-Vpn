import 'dart:io' show Platform, Process, exit;

/// رفع الصلاحيات على Windows.
/// - [isAdmin]: يفحص إن كانت العملية تعمل كمسؤول.
/// - [requestElevationAndExit]: يعيد تشغيل التطبيق بصلاحيات مسؤول ثم يخرج.
class WindowsElevation {
  /// هل نعمل كمسؤول على Windows؟
  /// على غير Windows → true دائماً.
  static Future<bool> isAdmin() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run('net', ['session'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// يطلب رفع الصلاحيات ويعيد تشغيل التطبيق، ثم يخرج من العملية الحالية.
  /// يعيد `false` إذا فشل الطلب (المستخدم رفض أو PowerShell غير متاح).
  static Future<bool> requestElevationAndExit() async {
    if (!Platform.isWindows) return true;
    try {
      final exePath = Platform.resolvedExecutable;
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Start-Process -FilePath "$exePath" -Verb RunAs',
        ],
      ).timeout(const Duration(seconds: 30));

      if (r.exitCode == 0) {
        await Future.delayed(const Duration(milliseconds: 300));
        exit(0);
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
