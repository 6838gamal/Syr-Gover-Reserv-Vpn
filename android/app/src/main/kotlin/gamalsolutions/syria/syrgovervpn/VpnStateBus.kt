package gamalsolutions.syria.syrgovervpn

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel

object VpnStateBus {
    private const val TAG = "VPN_TAG"
    private const val PREFS_NAME = "vpn_state_prefs"
    private const val KEY_LAST_ERROR = "last_error_message"
    private const val KEY_LAST_CONFIG = "last_config_name"

    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile private var appContext: Context? = null

    @Volatile private var _state: String = "disconnected"
    @Volatile private var _message: String? = null
    @Volatile private var _configName: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        _configName = appContext
            ?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.getString(KEY_LAST_CONFIG, null)
        Log.d(TAG, "VpnStateBus.init: restored configName=$_configName")
    }

    fun snapshot(): Map<String, Any?> {
        val running = try { MyVpnService.isRunning } catch (_: Throwable) { false }

        val actualState = when {
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
        val newConfig = when {
            state == "disconnected" || state == "error" -> null
            configName != null -> configName
            else -> _configName
        }

        if (state == _state && message == _message && newConfig == _configName) {
            Log.d(TAG, "emit skipped (no change): state=$state")
            return
        }

        Log.d(TAG, "VpnStateBus.emit: state=$state msg=$message config=$newConfig")
        _state = state
        _message = message
        _configName = newConfig

        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (state == "error" && message != null) {
            prefs?.edit()?.putString(KEY_LAST_ERROR, message)?.apply()
        }
        if (newConfig != null) {
            prefs?.edit()?.putString(KEY_LAST_CONFIG, newConfig)?.apply()
        } else {
            prefs?.edit()?.remove(KEY_LAST_CONFIG)?.apply()
        }

        mainHandler.post {
            try {
                sink?.success(snapshot())
            } catch (e: Throwable) {
                Log.w(TAG, "sink.success failed (sink likely closed): ${e.message}")
            }
        }
    }

    /// ✅ إرفاق sink مع إرسال حالة أولية (ذرّي)
    fun attachSink(newSink: EventChannel.EventSink?) {
        sink = newSink
        if (newSink != null) {
            val snap = snapshot()
            mainHandler.post {
                try { newSink.success(snap) } catch (_: Throwable) {}
            }
        }
    }

    /// ✅ قراءة الخطأ المعلق بدون مسحه
    fun peekPendingError(): String? {
        return appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.getString(KEY_LAST_ERROR, null)
    }

    fun consumePendingError(): String? {
        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) ?: return null
        val err = prefs.getString(KEY_LAST_ERROR, null)
        if (err != null) {
            prefs.edit().remove(KEY_LAST_ERROR).apply()
        }
        return err
    }

    fun reset() {
        _state = "disconnected"
        _message = null
        _configName = null
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()?.remove(KEY_LAST_ERROR)?.remove(KEY_LAST_CONFIG)?.apply()

        mainHandler.post {
            try { sink?.success(snapshot()) } catch (_: Throwable) {}
        }
    }
}
