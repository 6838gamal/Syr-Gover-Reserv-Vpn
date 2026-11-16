enum LogLevel { info, warn, error }

class VpnLog {
  final DateTime time;
  final String message;
  final LogLevel level;

  VpnLog(this.message, {this.level = LogLevel.info}) : time = DateTime.now();

  String get formattedTime {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}
