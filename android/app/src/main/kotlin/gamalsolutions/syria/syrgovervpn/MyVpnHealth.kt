package gamalsolutions.syria.syrgovervpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.wireguard.android.backend.Tunnel

/**
 * فحص صحة النفق + Kill Switch.
 *
 * يُستدعى من MethodChannel handler في MainActivity.
 */
object MyVpnHealth {
    private const val TAG = "VPN_HEALTH"

    // ── Health ──────────────────────────────────────────────
    /**
     * يعيد: "good" | "suspect" | "down"
     *
     * المنطق:
     * - إذا لم تكن الخدمة تعمل → down
     * - إذا لم يكن هناك شبكة نظام → down
     * - إذا كانت الشبكة موجودة والنفق UP → good
     * - النفق DOWN رغم وجود شبكة → suspect (قد يكون في طور الاتصال)
     */
    fun probeHealth(): String {
        if (!MyVpnService.isRunning) {
            Log.d(TAG, "probeHealth: service not running → down")
            return "down"
        }

        val ctx = MyVpnService.appContext ?: return "suspect"

        // هل يوجد اتصال شبكة أصلاً؟
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "suspect"
        val network = cm.activeNetwork ?: return "down"
        val caps = cm.getNetworkCapabilities(network) ?: return "down"

        val hasInternet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (!hasInternet) {
            Log.d(TAG, "probeHealth: no internet → down")
            return "down"
        }

        // هل النفق نشط؟
        return when (MyVpnService.currentTunnelState) {
            Tunnel.State.UP -> "good"
            Tunnel.State.DOWN -> "down"
            else -> "suspect"
        }
    }

    // ── Kill Switch ─────────────────────────────────────────
    private const val KS_PREF = "vpn_kill_switch"
    private const val KS_KEY = "active"

    fun setKillSwitch(ctx: Context, enabled: Boolean) {
        val prefs = ctx.getSharedPreferences(KS_PREF, Context.MODE_PRIVATE)
        val current = prefs.getBoolean(KS_KEY, false)

        if (current == enabled) {
            Log.d(TAG, "setKillSwitch($enabled): already in that state")
            return
        }

        prefs.edit().putBoolean(KS_KEY, enabled).apply()
        Log.d(TAG, "setKillSwitch($enabled): saved")

        // ملاحظة: التنفيذ الفعلي على Android يتطلب إعادة بناء VpnService
        // (GoBackend لا يسمح بالتحكم الدقيق). حالياً نحفظ الحالة فقط.
        if (enabled) {
            Log.w(TAG, "Kill switch ENABLED — will apply on next connect")
        } else {
            Log.d(TAG, "Kill switch DISABLED")
        }
    }

    fun isKillSwitchActive(ctx: Context): Boolean {
        val prefs = ctx.getSharedPreferences(KS_PREF, Context.MODE_PRIVATE)
        return prefs.getBoolean(KS_KEY, false)
    }
}
