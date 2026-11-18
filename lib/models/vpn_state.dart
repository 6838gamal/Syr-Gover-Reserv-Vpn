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

  // ------------------------------------------------------------------
  // خصائص مساعدة
  // ------------------------------------------------------------------

  bool get isConnected => status == VpnStatus.connected;
  bool get isConnecting => status == VpnStatus.connecting;
  bool get isDisconnecting => status == VpnStatus.disconnecting;
  bool get hasError => status == VpnStatus.error;
  bool get isIdle => status == VpnStatus.disconnected;

  /// مدة الاتصال الحالية (null إذا لم يكن متصلاً).
  Duration? get connectedDuration {
    if (status != VpnStatus.connected || connectedSince == null) return null;
    return DateTime.now().difference(connectedSince!);
  }

  // ------------------------------------------------------------------
  // copyWith
  // ------------------------------------------------------------------

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

  // ------------------------------------------------------------------
  // toStatus — انتقال ذكي
  // ------------------------------------------------------------------

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

  // ------------------------------------------------------------------
  // toString (للتشخيص)
  // ------------------------------------------------------------------

  @override
  String toString() {
    final parts = <String>['status=${status.name}'];
    if (errorMessage != null) parts.add('error=$errorMessage');
    if (activeConfigName != null) parts.add('config=$activeConfigName');
    if (connectedSince != null) {
      final d = connectedDuration;
      if (d != null) parts.add('uptime=${d.inSeconds}s');
    }
    return 'VpnState(${parts.join(', ')})';
  }

  // ------------------------------------------------------------------
  // == و hashCode (للمقارنة)
  // ------------------------------------------------------------------

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VpnState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          errorMessage == other.errorMessage &&
          activeConfigName == other.activeConfigName &&
          connectedSince == other.connectedSince;

  @override
  int get hashCode =>
      status.hashCode ^
      errorMessage.hashCode ^
      activeConfigName.hashCode ^
      connectedSince.hashCode;
}
