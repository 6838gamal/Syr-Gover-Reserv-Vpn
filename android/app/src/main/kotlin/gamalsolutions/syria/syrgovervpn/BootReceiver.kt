package gamalsolutions.syria.syrgovervpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "VPN_TAG"
        private const val AUTOSTART_CHANNEL_ID = "autostart_channel"
        private const val AUTOSTART_NOTIF_ID = 2001
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "BootReceiver received: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> handleAutostart(context, intent)

            else -> Log.d(TAG, "BootReceiver: ignored action ${intent.action}")
        }
    }

    private fun handleAutostart(context: Context, intent: Intent) {
        // 0) إذا كان VPN يعمل بالفعل
        if (MyVpnService.isRunning) {
            Log.i(TAG, "VPN يعمل بالفعل — لا حاجة لإعادة التشغيل")
            return
        }

        // 1) Always-on VPN — النظام سيتكفل
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
            NotificationErrorLogger.log(
                context, "BootReceiver/noConfig", null, "last config is null"
            )
            return
        }
        Log.i(TAG, "loaded last config keys=${config.keys}")

        // 4) صلاحية VPN؟
        val prepareIntent = VpnService.prepare(context)
        if (prepareIntent != null) {
            Log.w(TAG, "صلاحية VPN غير ممنوحة — لن يبدأ auto-start")
            NotificationErrorLogger.log(
                context, "BootReceiver/noVpnPermission", null,
                "prepare() returned non-null on boot"
            )
            // لا يمكن عرض dialog الصلاحية من BroadcastReceiver
            // الحل: إشعار يطلب من المستخدم فتح التطبيق
            showAutostartNeedsPermissionNotification(context)
            return
        }

        // 5) شغّل الخدمة — مع معالجة ForegroundServiceStartNotAllowedException
        Log.i(TAG, "بدء VPN تلقائياً")
        try {
            MyVpnService.start(context, config)
            Log.i(TAG, "MyVpnService.start dispatched OK")
        } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
            // Android 12+ — لا يمكن بدء FGS من الخلفية
            Log.e(TAG, "ForegroundServiceStartNotAllowedException", e)
            NotificationErrorLogger.log(
                context, "BootReceiver/FGSNotAllowed", e,
                "Android 12+ restricts FGS start from BOOT_COMPLETED. " +
                    "Recommend enabling Always-On VPN in system settings."
            )
            showAutostartBlockedNotification(context)
        } catch (e: Throwable) {
            Log.e(TAG, "autostart failed", e)
            NotificationErrorLogger.log(context, "BootReceiver/start", e)
        }
    }

    // ------------------------------------------------------------------
    // إشعارات إرشادية (عند فشل auto-start)
    // ------------------------------------------------------------------

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                AUTOSTART_CHANNEL_ID,
                "Auto-start",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "إشعارات عند فشل التشغيل التلقائي لـ VPN"
            }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    private fun buildNotif(context: Context, title: String, text: String): android.app.Notification {
        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP }
        val pi = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_IMMUTABLE else 0)
        )
        return NotificationCompat.Builder(context, AUTOSTART_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
    }

    private fun showAutostartNeedsPermissionNotification(context: Context) {
        ensureChannel(context)
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                AUTOSTART_NOTIF_ID,
                buildNotif(
                    context,
                    "VPN يحتاج صلاحية",
                    "افتح التطبيق لمنح صلاحية VPN ليعمل تلقائياً."
                )
            )
        } catch (e: Throwable) {
            NotificationErrorLogger.log(context, "BootReceiver/showNotifPermission", e)
        }
    }

    private fun showAutostartBlockedNotification(context: Context) {
        ensureChannel(context)
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                AUTOSTART_NOTIF_ID,
                buildNotif(
                    context,
                    "لم يبدأ VPN تلقائياً",
                    "فعّل \"Always-On VPN\" من إعدادات النظام، أو افتح التطبيق واتصل يدوياً."
                )
            )
        } catch (e: Throwable) {
            NotificationErrorLogger.log(context, "BootReceiver/showNotifBlocked", e)
        }
    }
}
