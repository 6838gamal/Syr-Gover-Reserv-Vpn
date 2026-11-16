package gamalsolutions.syria.syrgovervpn

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
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
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (e: Exception) {
                Log.e(TAG, "startForegroundService failed", e)
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
        // لا نُلغي scope قبل إغلاق النفق — نُلغيه بعد
        scope.cancel()
        backend = null
        tunnel = null
        instance = null
        isRunning = false
        VpnStateBus.emit("disconnected", null)
        stopForegroundCompat()
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Intent handlers
    // ------------------------------------------------------------------

    private fun handleConnectIntent(intent: Intent) {
        // 1) foreground notification أولاً (إلزامي خلال 5 ثوان)
        startForeground(NOTIF_ID, buildNotification("جارٍ الاتصال..."))

        // 2) استخراج args
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

        // 3) بدء الاتصال في coroutine
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
        currentConfigName = args["configName"] as? String
        scope.launch {
            try {
                VpnStateBus.emit("connecting", currentConfigName)
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
                ConfigPersistence.setAutostart(this@MyVpnService, true)

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

                // إنشاء/إعادة استخدام Backend
                if (backend == null) {
                    Log.d(TAG, "creating GoBackend")
                    backend = GoBackend(this@MyVpnService)
                }

                val t = WgTunnel(currentConfigName ?: "myvpn")
                tunnel = t

                Log.d(TAG, "calling setState(UP)")
                backend!!.setState(t, Tunnel.State.UP, cfg)
                Log.i(TAG, "tunnel UP")

                VpnStateBus.emit("connected", currentConfigName)
                updateNotification("متصل${currentConfigName?.let { " — $it" } ?: ""}")
            } catch (e: Throwable) {
                Log.e(TAG, "connect failed", e)
                VpnStateBus.emit("error", e.message ?: e.toString())
                updateNotification("خطأ: ${e.message}")
                // لا stopSelf هنا — نُبقي الإشعار ليرى المستخدم الخطأ
                // لكن نُعيد الحالة إلى disconnected بعد إغلاق النفق
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
class WgTunnel(name: String = "myvpn") : Tunnel {
    @Volatile private var _name: String = name
    @Volatile private var _state: Tunnel.State = Tunnel.State.DOWN

    override fun getName(): String = _name

    override fun onStateChange(newState: Tunnel.State) {
        _state = newState
        Log.d("VPN_TAG", "WgTunnel[$_name].onStateChange → $newState")
        when (newState) {
            Tunnel.State.UP -> VpnStateBus.emit("connected", _name)
            Tunnel.State.DOWN -> VpnStateBus.emit("disconnected", null)
            Tunnel.State.TOGGLE -> { /* غير مستخدم عملياً */ }
        }
    }

    var state: Tunnel.State
        get() = _state
        set(v) { _state = v }
}
