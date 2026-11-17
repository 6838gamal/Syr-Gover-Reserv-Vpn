package gamalsolutions.syria.syrgovervpn

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlinx.coroutines.*

class MyVpnService : VpnService() {

    companion object {
        private const val TAG = "VPN_TAG"
        private const val CHANNEL_ID = "vpn_channel"
        private const val NOTIF_ID = 1001
        private const val ACTION_CONNECT = "connect"
        private const val ACTION_DISCONNECT = "disconnect"
        private const val ACTION_KICK = "kick"

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        private var instance: MyVpnService? = null

        fun start(ctx: Context, args: Map<String, Any>) {
            Log.d(TAG, "MyVpnService.start args=${args.keys}")
            val i = Intent(ctx, MyVpnService::class.java).apply {
                action = ACTION_CONNECT
                args.forEach { (k, v) ->
                    when (v) {
                        is String -> putExtra(k, v)
                        is Int -> putExtra(k, v)
                        is Long -> putExtra(k, v)
                        is Boolean -> putExtra(k, v)
                        else -> Log.w(TAG, "skip extra $k: unsupported type ${v::class}")
                    }
                }
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    if (isAppInForeground(ctx)) {
                        Log.d(TAG, "startService (app in foreground)")
                        ctx.startService(i)
                    } else {
                        Log.d(TAG, "startForegroundService (app in background)")
                        ctx.startForegroundService(i)
                    }
                } else {
                    ctx.startService(i)
                }
            } catch (e: Exception) {
                Log.e(TAG, "service start failed", e)
                VpnStateBus.emit("error", e.message ?: e.toString())
                throw e
            }
        }

        fun stop(ctx: Context) {
            Log.d(TAG, "MyVpnService.stop")
            try {
                ctx.startService(Intent(ctx, MyVpnService::class.java).apply {
                    action = ACTION_DISCONNECT
                })
            } catch (e: Exception) {
                Log.e(TAG, "stop failed", e)
            }
        }

        fun kick() {
            Log.d(TAG, "MyVpnService.kick")
            instance?.let { svc ->
                svc.scope.launch {
                    try { svc.reconnect() }
                    catch (e: Throwable) {
                        Log.e(TAG, "kick reconnect failed", e)
                        VpnStateBus.emit("error", e.message ?: e.toString())
                    }
                }
            } ?: Log.w(TAG, "kick called but service not running")
        }

        private fun isAppInForeground(ctx: Context): Boolean {
            return try {
                val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val processes = am.runningAppProcesses ?: return false
                val myPid = android.os.Process.myPid()
                val myUid = android.os.Process.myUid()
                processes.any {
                    it.pid == myPid && it.uid == myUid &&
                        it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                }
            } catch (_: Exception) {
                false
            }
        }
    }

    private var tunnel: WgTunnel? = null
    private var backend: GoBackend? = null
    private var lastArgs: Map<String, Any>? = null
    private var currentConfigName: String? = null
    internal val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        instance = this
        isRunning = true
        createChannel()
        startForeground(NOTIF_ID, buildNotification("جارٍ الاتصال..."))
        VpnStateBus.emit("connecting", null, null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")
        when (intent?.action) {
            ACTION_CONNECT -> handleConnectIntent(intent)
            ACTION_DISCONNECT -> handleDisconnectIntent()
            ACTION_KICK -> kick()
            else -> Log.w(TAG, "unknown action: ${intent?.action}")
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        try {
            tunnel?.let { t -> backend?.setState(t, Tunnel.State.DOWN, null) }
        } catch (e: Throwable) {
            Log.w(TAG, "error bringing tunnel down on destroy", e)
        }
        scope.cancel()
        backend = null
        tunnel = null
        instance = null
        isRunning = false
        VpnStateBus.emit("disconnected", null, null)
        stopForegroundCompat()
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Intent handlers
    // ------------------------------------------------------------------

    private fun handleConnectIntent(intent: Intent) {
        val args = mutableMapOf<String, Any>()
        intent.extras?.keySet()?.forEach { k ->
            intent.extras?.get(k)?.let { v -> args[k] = v }
        }
        if (args.isEmpty()) {
            Log.e(TAG, "connect intent with no args")
            VpnStateBus.emit("error", "no config args")
            stopForegroundCompat()
            stopSelf()
            return
        }
        connect(args)
    }

    private fun handleDisconnectIntent() {
        Log.d(TAG, "handling disconnect")
        VpnStateBus.emit("disconnecting", null)
        scope.launch {
            try {
                tunnel?.let { t ->
                    Log.d(TAG, "bringing tunnel DOWN")
                    backend?.setState(t, Tunnel.State.DOWN, null)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "disconnect setState failed", e)
                VpnStateBus.emit("error", e.message ?: e.toString())
            } finally {
                tunnel = null
                VpnStateBus.emit("disconnected", null)
                stopForegroundCompat()
                stopSelf()
            }
        }
    }

    // ------------------------------------------------------------------
    // Connect / reconnect
    // ------------------------------------------------------------------

    private fun connect(args: Map<String, Any>) {
        lastArgs = args
        // ✅ الحل: اقرأ الاسم، وإذا لم يوجد استخدم اسم افتراضي
        currentConfigName = args["configName"] as? String ?: "VPN Config"

        scope.launch {
            try {
                VpnStateBus.emit("connecting", null, currentConfigName)
                updateNotification("جارٍ الاتصال بـ $currentConfigName...") // ✅ تحديث الإشعار فوراً

                Log.d(TAG, "checking VPN permission via prepare()")
                if (prepare(this@MyVpnService) != null) {
                    Log.e(TAG, "prepare() returned non-null → permission missing")
                    VpnStateBus.emit("error", "صلاحية VPN مطلوبة")
                    updateNotification("صلاحية VPN مطلوبة")
                    stopForegroundCompat()
                    stopSelf()
                    return@launch
                }

                ConfigPersistence.saveLastConfig(this@MyVpnService, args)

                Log.d(TAG, "building wireguard config")
                val cfg = try {
                    buildConfig(args)
                } catch (e: Throwable) {
                    Log.e(TAG, "buildConfig failed", e)
                    VpnStateBus.emit("error", "config invalid: ${e.message}")
                    updateNotification("إعدادات غير صالحة")
                    stopForegroundCompat()
                    stopSelf()
                    return@launch
                }

                if (backend == null) {
                    Log.d(TAG, "creating GoBackend")
                    backend = GoBackend(this@MyVpnService)
                }

                val t = WgTunnel(currentConfigName ?: "VPN Config")
                tunnel = t

                Log.d(TAG, "calling setState(UP)")
                try {
                    backend!!.setState(t, Tunnel.State.UP, cfg)
                    Log.i(TAG, "tunnel UP")
                    // ✅ إرسال صريح — لا نعتمد على WgTunnel.onStateChange فقط
                    VpnStateBus.emit("connected", null, currentConfigName)
                    updateNotification("متصل — $currentConfigName") // ✅ تحديث الإشعار
                } catch (e: Throwable) {
                    Log.e(TAG, "setState(UP) failed", e)
                    VpnStateBus.emit("error", "فشل الاتصال: ${e.message}")
                    updateNotification("خطأ: ${e.message}")
                    stopSelf()
                }
            } catch (e: Throwable) {
                Log.e(TAG, "connect failed", e)
                VpnStateBus.emit("error", e.message ?: e.toString())
                updateNotification("خطأ: ${e.message}")
                try {
                    tunnel?.let { t -> backend?.setState(t, Tunnel.State.DOWN, null) }
                } catch (_: Throwable) {}
                tunnel = null
            }
        }
    }

    internal fun reconnect() {
        Log.d(TAG, "reconnect()")
        val args = lastArgs ?: run {
            Log.w(TAG, "reconnect: no lastArgs")
            return
        }
        try {
            tunnel?.let { t -> backend?.setState(t, Tunnel.State.DOWN, null) }
        } catch (e: Throwable) {
            Log.w(TAG, "reconnect: down failed", e)
        }
        tunnel = null
        connect(args)
    }

    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------

    private fun buildConfig(args: Map<String, Any>): Config {
        val iface = com.wireguard.config.Interface.Builder()
            .parsePrivateKey(args["privateKey"] as String)
            .parseAddresses(args["address"] as String)
            .parseDnsServers(args["dns"] as String)
            .build()

        val peer = com.wireguard.config.Peer.Builder()
            .parsePublicKey(args["peerPublicKey"] as String)
            .parseEndpoint(args["endpoint"] as String)
            .parseAllowedIPs(args["allowedIps"] as String)
            .parsePersistentKeepalive(
                (args["persistentKeepalive"] as Int).toString()
            )
            .build()

        return Config.Builder().setInterface(iface).addPeer(peer).build()
    }

    // ------------------------------------------------------------------
    // Notification
    // ------------------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "VPN", NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("My VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(text: String) {
        try {
            // ✅ تحقق من POST_NOTIFICATIONS على Android 13+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val granted = ContextCompat.checkSelfPermission(
                    this, Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
                if (!granted) {
                    Log.w(TAG, "POST_NOTIFICATIONS not granted — skipping notification update")
                    return
                }
            }
            Log.d(TAG, "updateNotification: $text")
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))
        } catch (e: Exception) {
            Log.w(TAG, "updateNotification failed", e)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}

// ------------------------------------------------------------------
// WgTunnel
// ------------------------------------------------------------------
class WgTunnel(
    private val configName: String = "VPN Config"
) : Tunnel {
    @Volatile private var _state: Tunnel.State = Tunnel.State.DOWN

    override fun getName(): String = configName

    override fun onStateChange(newState: Tunnel.State) {
        _state = newState
        Log.d("VPN_TAG", "WgTunnel[$configName].onStateChange → $newState")
        when (newState) {
            Tunnel.State.UP ->
                VpnStateBus.emit("connected", null, configName)
            Tunnel.State.DOWN ->
                VpnStateBus.emit("disconnected", null)
            Tunnel.State.TOGGLE -> { /* غير مستخدم */ }
        }
    }

    var state: Tunnel.State
        get() = _state
        set(v) { _state = v }
}
