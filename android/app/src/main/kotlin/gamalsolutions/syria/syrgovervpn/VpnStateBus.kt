package gamalsolutions.syria.syrgovervpn

import android.util.Log
import io.flutter.plugin.common.EventChannel

object VpnStateBus {
    private const val TAG = "VPN_TAG"

    var sink: EventChannel.EventSink? = null

    @Volatile private var _state: String = "disconnected"
    @Volatile private var _message: String? = null
    @Volatile private var _configName: String? = null

    /**
     * snapshot() يقرأ الحالة الحقيقية:
     * - إذا كانت الخدمة تعمل لكن _state = disconnected، نُعيد "connected"
     * - هذا يضمن أن التطبيق لا يرى "غير متصل" بينما الإشعار يقول "متصل"
     */
    fun snapshot(): Map<String, Any?> {
        val running = try { MyVpnService.isRunning } catch (_: Throwable) { false }
        val actualState = when {
            _state == "disconnected" && running -> "connected"
            else -> _state
        }
        Log.d(TAG, "VpnStateBus.snapshot: state=$actualState (raw=$_state) running=$running")
        return mapOf(
            "state" to actualState,
            "status" to actualState,
            "message" to _message,
            "error" to _message,
            "configName" to _configName,
        )
    }

    fun emit(state: String, message: String? = null, configName: String? = null) {
        Log.d(TAG, "VpnStateBus.emit: state=$state msg=$message config=$configName")
        _state = state
        _message = message
        if (configName != null) _configName = configName
        if (state == "disconnected" || state == "error") {
            _configName = null
        }
        sink?.success(snapshot())
    }

    @Deprecated("Use emit()", ReplaceWith("emit(status, error, configName)"))
    fun set(status: String, error: String? = null, configName: String? = null) {
        emit(status, error, configName)
    }
}
