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
  }) =>
      VpnState(
        status: status ?? this.status,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        activeConfigName: activeConfigName ?? this.activeConfigName,
        connectedSince: connectedSince ?? this.connectedSince,
      );
}
