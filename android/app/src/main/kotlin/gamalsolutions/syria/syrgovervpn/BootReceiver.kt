package gamalsolutions.syria.syrgovervpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs: SharedPreferences = context.getSharedPreferences("vpn", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autostart", false)) return
        // إذا كان المستخدم قد فعّل "Always-on VPN" في إعدادات النظام
        // فالنظام سيتكفل بالتشغيل — لا حاجة لعمل شيء هنا.
    }
}
