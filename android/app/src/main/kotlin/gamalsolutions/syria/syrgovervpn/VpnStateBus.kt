package gamalsolutions.syria.syrgovervpn

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.EventChannel

object VpnStateBus {
    private const val TAG = "VPN_TAG"
    private const val PREFS_NAME = "vpn_state_prefs"
    private const val KEY_LAST_ERROR = "last_error_message"

    var sink: EventChannel.EventSink? = null
    private var appContext: Context? = null

    @Volatile private var _state: String = "disconnected"
    @Volatile private var _message: String? = null
    @Volatile private var _configName: String? = null

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

    fun snapshot(): Map<String, Any?> {
        val running = try { MyVpnService.isRunning } catch (_: Throwable) { false }
        val actualState = when {
            running && _state == "connecting" -> "connected"
            !running && _state != "disconnected" -> "disconnected"
            else -> _state
        }
        return mapOf(
            "state" to actualState,
            "status" to actualState,
            "message" to _message,
            "error" to _message,
            "configName" to _configName,
        )
    }

    fun emit(state: String, message: String? = null, configName: String? = null) {
        Log.d(TAG, "VpnStateBus.emit: state=$state msg=$message")
        _state = state
        _message = message
        if (configName != null) _configName = configName
        if (state == "disconnected" || state == "error") {
            _configName = null
        }
        sink?.success(snapshot())
        
        // ✅ حفظ الأخطاء في الذاكرة ليقرأها Flutter لاحقاً
        if (state == "error" && message != null) {
            appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                ?.edit()?.putString(KEY_LAST_ERROR, message)?.apply()
        }
    }

    fun consumePendingError(): String? {
        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return null
        val err = prefs.getString(KEY_LAST_ERROR, null)
        if (err != null) {
            prefs.edit().remove(KEY_LAST_ERROR).apply() // امسحها بعد قراءتها
        }
        return err
    }
}
