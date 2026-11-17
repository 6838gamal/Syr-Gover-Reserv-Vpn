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

                // 0) إذا كان VPN يعمل بالفعل، لا حاجة لإعادة التشغيل
                if (MyVpnService.isRunning) {
                    Log.i(TAG, "VPN يعمل بالفعل — لا حاجة لإعادة التشغيل")
                    return
                }

                // 1) Always-on VPN
                val alwaysOn = intent.getBooleanExtra("alwaysOn", false)
                if (alwaysOn) {
                    Log.i(TAG, "Always-on VPN — النظام سيتكفل")
                    return
                }

                // 2) auto-start مفعّل؟
                if (!ConfigPersistence.isAutostartEnabled(context)) {
                    Log.i(TAG, "Auto-start معطّل")
                    return
                }

                // 3) إعدادات محفوظة؟
                val config = ConfigPersistence.loadLastConfig(context)
                if (config == null) {
                    Log.w(TAG, "لا توجد إعدادات محفوظة")
                    return
                }
                Log.i(TAG, "loaded last config keys=${config.keys}")

                // 4) صلاحية VPN؟
                val prepareIntent = VpnService.prepare(context)
                if (prepareIntent != null) {
                    // على BOOT_COMPLETED لا يمكن عرض dialog الصلاحية
                    Log.w(TAG, "صلاحية VPN غير ممنوحة — لن يبدأ auto-start")
                    return
                }

                // 5) شغّل الخدمة
                Log.i(TAG, "بدء VPN تلقائياً")
                try {
                    MyVpnService.start(context, config)
                    Log.i(TAG, "MyVpnService.start dispatched OK")
                } catch (e: Exception) {
                    Log.e(TAG, "autostart failed", e)
                    // ForegroundServiceStartNotAllowedException محتمل على Android 12+
                }
            }

            else -> Log.d(TAG, "BootReceiver: ignored action ${intent.action}")
        }
    }
}
