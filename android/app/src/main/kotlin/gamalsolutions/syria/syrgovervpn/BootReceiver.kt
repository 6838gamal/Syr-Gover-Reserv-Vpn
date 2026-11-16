package gamalsolutions.syria.syrgovervpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "VPN_TAG"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "BootReceiver received: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {

                // 1) إذا كان Always-on VPN مفعّلاً في النظام، النظام سيشغل
                //    الخدمة تلقائياً — لا حاجة لفعل شيء.
                val alwaysOn = intent.getBooleanExtra("alwaysOn", false)
                if (alwaysOn) {
                    Log.i(TAG, "Always-on VPN — النظام سيتكفل")
                    return
                }

                // 2) هل المستخدم فعّل auto-start لدينا؟
                if (!ConfigPersistence.isAutostartEnabled(context)) {
                    Log.i(TAG, "Auto-start معطّل")
                    return
                }

                // 3) هل توجد إعدادات محفوظة؟
                val config = ConfigPersistence.loadLastConfig(context)
                if (config == null) {
                    Log.w(TAG, "لا توجد إعدادات محفوظة")
                    return
                }

                // 4) هل لدينا صلاحية VPN؟ (يجب أن يكون المستخدم وافق مسبقاً)
                if (VpnService.prepare(context) != null) {
                    Log.w(TAG, "صلاحية VPN غير ممنوحة")
                    VpnStateBus.emit("error", "صلاحية VPN غير ممنوحة")
                    return
                }

                // 5) شغّل الخدمة
                Log.i(TAG, "بدء VPN تلقائياً")
                try {
                    MyVpnService.start(context, config)
                    Log.i(TAG, "MyVpnService.start dispatched")
                } catch (e: Exception) {
                    Log.e(TAG, "autostart failed", e)
                    VpnStateBus.emit("error", "autostart failed: ${e.message}")
                }
            }

            else -> Log.d(TAG, "BootReceiver: ignored action ${intent.action}")
        }
    }
}
