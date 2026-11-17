package gamalsolutions.syria.syrgovervpn

import android.util.Log
import io.flutter.plugin.common.EventChannel

object VpnStateBus {
    private const val TAG = "VPN_TAG"

    var sink: EventChannel.EventSink? = null

    @Volatile private var _state: String = "disconnected"
    @Volatile private var _message: String? = null
    @Volatile private var _configName: String? = null

    /** الحالة الحالية كخريطة جاهزة للإرسال. */
    fun snapshot(): Map<String, Any?> = mapOf(
        // نرسل المفتاحين معاً للتوافق مع Dart القديم والجديد
        "state" to _state,
        "status" to _state,
        "message" to _message,
        "error" to _message,
        "configName" to _configName,
    )

    /**
     * الطريقة المفضلة للبث.
     * @param state واحدة من: connecting | connected | disconnecting | disconnected | error
     */
    fun emit(state: String, message: String? = null, configName: String? = null) {
        Log.d(TAG, "VpnStateBus.emit: state=$state msg=$message config=$configName")
        _state = state
        _message = message
        if (configName != null) _configName = configName
        sink?.success(snapshot())
    }

    /** توافق خلفي مع الكود القديم. */
    @Deprecated("Use emit()", ReplaceWith("emit(status, error, configName)"))
    fun set(status: String, error: String? = null, configName: String? = null) {
        emit(status, error, configName)
    }
}
