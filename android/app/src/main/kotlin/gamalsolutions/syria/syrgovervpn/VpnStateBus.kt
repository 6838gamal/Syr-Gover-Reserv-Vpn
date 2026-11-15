package gamalsolutions.syria.syrgovervpn

import io.flutter.plugin.common.EventChannel

object VpnStateBus {
    var sink: EventChannel.EventSink? = null
    private var _status = "disconnected"
    private var _error: String? = null
    private var _configName: String? = null

    fun snapshot(): Map<String, Any?> = mapOf(
        "status" to _status,
        "error" to _error,
        "configName" to _configName
    )

    fun set(status: String, error: String? = null, configName: String? = null) {
        _status = status
        _error = error
        if (configName != null) _configName = configName
        sink?.success(snapshot())
    }
}
