enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

class VpnState {
  final VpnStatus status;
  final String? errorMessage;
  final String? activeConfigName;
  final DateTime? connectedSince;

  const VpnState({
    this.status = VpnStatus.disconnected,
    this.errorMessage,
    this.activeConfigName,
    this.connectedSince,
  });

  VpnState copyWith({
    VpnStatus? status,
    String? errorMessage,
    String? activeConfigName,
    DateTime? connectedSince,
    bool clearError = false,
    bool clearConnectedSince = false,
    bool clearActiveConfig = false,
  }) {
    return VpnState(
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      activeConfigName:
          clearActiveConfig ? null : (activeConfigName ?? this.activeConfigName),
      connectedSince:
          clearConnectedSince ? null : (connectedSince ?? this.connectedSince),
    );
  }

  /// انتقال ذكي: يضبط/يمسح `connectedSince` تلقائياً حسب الحالة الجديدة.
  VpnState toStatus(
    VpnStatus next, {
    String? errorMessage,
    String? activeConfigName,
  }) {
    final nowConnected = next == VpnStatus.connected;
    final wasConnected = status == VpnStatus.connected;

    return VpnState(
      status: next,
      errorMessage: next == VpnStatus.error
          ? (errorMessage ?? this.errorMessage)
          : null,
      activeConfigName: next == VpnStatus.disconnected || next == VpnStatus.error
          ? null
          : (activeConfigName ?? this.activeConfigName),
      connectedSince: nowConnected
          ? (wasConnected ? connectedSince : DateTime.now())
          : null,
    );
  }

  /// مدة الاتصال الحالية (null إذا لم يكن متصلاً).
  Duration? get connectedDuration {
    if (status != VpnStatus.connected || connectedSince == null) return null;
    return DateTime.now().difference(connectedSince!);
  }
}
