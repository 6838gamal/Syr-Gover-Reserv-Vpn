package com.example.myvpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i("BootReceiver", "Received: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {

                // 1. إذا كان Always-on VPN مفعّلاً في النظام، النظام سيشغل
                //    الخدمة تلقائياً — لا حاجة لفعل شيء. لنتحقق:
                val alwaysOn = intent.getBooleanExtra("alwaysOn", false)
                if (alwaysOn) {
                    Log.i("BootReceiver", "Always-on VPN — النظام سيتكفل")
                    return
                }

                // 2. هل المستخدم فعّل auto-start لدينا؟
                if (!ConfigPersistence.isAutostartEnabled(context)) {
                    Log.i("BootReceiver", "Auto-start معطّل")
                    return
                }

                // 3. هل توجد إعدادات محفوظة؟
                val config = ConfigPersistence.loadLastConfig(context)
                if (config == null) {
                    Log.w("BootReceiver", "لا توجد إعدادات محفوظة")
                    return
                }

                // 4. هل لدينا صلاحية VPN؟ (يجب أن يكون المستخدم وافق مسبقاً)
                if (VpnService.prepare(context) != null) {
                    Log.w("BootReceiver", "صلاحية VPN غير ممنوحة")
                    return
                }

                // 5. شغّل الخدمة
                Log.i("BootReceiver", "بدء VPN تلقائياً")
                MyVpnService.start(context, config)
            }
        }
    }
}
