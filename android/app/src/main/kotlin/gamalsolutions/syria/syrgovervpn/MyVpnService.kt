package gamalsolutions.syria.syrgovervpn

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlinx.coroutines.*

// ==================================================================
// NotificationErrorLogger — سجل أخطاء دائم للإشعارات
// ==================================================================
object NotificationErrorLogger {
    private const val TAG = "NOTIF_LOG"
    private const val FILE_NAME = "notification_errors.log"
    private const val MAX_SIZE = 512 * 1024 // 512KB

    private val fmt = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", java.util.Locale.US)

    fun log(context: Context, stage: String, error: Throwable? = null, extra: String? = null) {
        val msg = buildString {
            append("[${fmt.format(java.util.Date())}]")
            append(" [$stage] ")
            append(error?.message ?: "no-exception")
            if (!extra.isNullOrBlank()) append(" | ").append(extra)
            error?.stackTraceToString()?.let { append("\n").append(it) }
        }
        Log.e(TAG, msg, error)

        // 1) ملف دائم
        try {
            val f = java.io.File(context.filesDir, FILE_NAME)
            if (f.exists() && f.length() > MAX_SIZE) f.delete()
            f.appendText(msg + "\n")
        } catch (_: Throwable) {}

        // 2) بث للحالة (إن وُجد مستمع)
        try { VpnStateBus.emit("notification_error", msg) } catch (_: Throwable) {}
    }

    fun readAll(context: Context): String = try {
        java.io.File(context.filesDir, FILE_NAME).readText()
    } catch (_: Throwable) { "" }

    fun clear(context: Context) {
        try { java.io.File(context.filesDir, FILE_NAME).delete() } catch (_: Throwable) {}
    }
}

// ==================================================================
// MyVpnService
// ==================================================================
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
                NotificationErrorLogger.log(ctx, "start/startService", e)
                try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
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
                NotificationErrorLogger.log(ctx, "stop/startService", e)
            }
        }

        fun kick() {
            Log.d(TAG, "MyVpnService.kick")
            instance?.let { svc ->
                svc.scope.launch {
                    try { svc.reconnect() }
                    catch (e: Throwable) {
                        Log.e(TAG, "kick reconnect failed", e)
                        NotificationErrorLogger.log(svc, "kick/reconnect", e)
                        try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
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

        try {
            createChannel()
            startForegroundSafe(buildNotification("جارٍ الاتصال..."))
            try { VpnStateBus.emit("connecting", null, null) } catch (_: Throwable) {}
        } catch (e: Throwable) {
            NotificationErrorLogger.log(this, "onCreate/startForeground", e)
            try { VpnStateBus.emit("error", "فشل بدء الإشعار: ${e.message}") } catch (_: Throwable) {}
            // لا نُسقط الخدمة، لكن نُعلم المستخدم
        }
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
            NotificationErrorLogger.log(this, "onDestroy/setStateDown", e)
        }
        scope.cancel()
        backend = null
        tunnel = null
        instance = null
        isRunning = false

        // ✅ إعادة تعيين الحالة في VpnStateBus
        try { VpnStateBus.reset() } catch (_: Throwable) {}

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
            NotificationErrorLogger.log(this, "handleConnectIntent/emptyArgs", null, "no extras")
            try { VpnStateBus.emit("error", "no config args") } catch (_: Throwable) {}
            stopForegroundCompat()
            stopSelf()
            return
        }
        connect(args)
    }

    private fun handleDisconnectIntent() {
        Log.d(TAG, "handling disconnect")
        try { VpnStateBus.emit("disconnecting", null) } catch (_: Throwable) {}
        scope.launch {
            try {
                tunnel?.let { t ->
                    Log.d(TAG, "bringing tunnel DOWN")
                    backend?.setState(t, Tunnel.State.DOWN, null)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "disconnect setState failed", e)
                NotificationErrorLogger.log(this@MyVpnService, "disconnect/setStateDown", e)
                try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
            } finally {
                tunnel = null
                try { VpnStateBus.emit("disconnected", null) } catch (_: Throwable) {}
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
        currentConfigName = args["configName"] as? String ?: "VPN Config"

        scope.launch {
            try {
                try { VpnStateBus.emit("connecting", null, currentConfigName) } catch (_: Throwable) {}
                updateNotification("جارٍ الاتصال بـ $currentConfigName...")

                Log.d(TAG, "checking VPN permission via prepare()")
                if (prepare(this@MyVpnService) != null) {
                    Log.e(TAG, "prepare() returned non-null → permission missing")
                    NotificationErrorLogger.log(this@MyVpnService, "connect/prepare", null, "VPN permission missing")
                    try { VpnStateBus.emit("error", "صلاحية VPN مطلوبة") } catch (_: Throwable) {}
                    updateNotification("صلاحية VPN مطلوبة")
                    stopForegroundCompat()
                    stopSelf()
                    return@launch
                }

                try {
                    ConfigPersistence.saveLastConfig(this@MyVpnService, args)
                } catch (e: Throwable) {
                    NotificationErrorLogger.log(this@MyVpnService, "connect/saveLastConfig", e)
                }

                Log.d(TAG, "building wireguard config")
                val cfg = try {
                    buildConfig(args)
                } catch (e: Throwable) {
                    Log.e(TAG, "buildConfig failed", e)
                    NotificationErrorLogger.log(this@MyVpnService, "connect/buildConfig", e, "args=${args.keys}")
                    try { VpnStateBus.emit("error", "إعدادات غير صالحة: ${e.message}") } catch (_: Throwable) {}
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
                    Log.i(TAG, "tunnel UP successfully")

                    try { VpnStateBus.emit("connected", null, currentConfigName) } catch (_: Throwable) {}
                    updateNotification("متصل — $currentConfigName")

                } catch (e: Throwable) {
                    Log.e(TAG, "WireGuard setState(UP) FAILED", e)
                    NotificationErrorLogger.log(this@MyVpnService, "connect/setStateUp", e, "config=$currentConfigName")
                    try { VpnStateBus.emit("error", "فشل النفق: ${e.message}") } catch (_: Throwable) {}
                    updateNotification("فشل الاتصال")
                }
            } catch (e: Throwable) {
                Log.e(TAG, "connect failed", e)
                NotificationErrorLogger.log(this@MyVpnService, "connect/outer", e)
                try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
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
            NotificationErrorLogger.log(this, "reconnect", null, "no lastArgs")
            return
        }
        try {
            tunnel?.let { t -> backend?.setState(t, Tunnel.State.DOWN, null) }
        } catch (e: Throwable) {
            Log.w(TAG, "reconnect: down failed", e)
            NotificationErrorLogger.log(this, "reconnect/setStateDown", e)
        }
        tunnel = null
        connect(args)
    }

    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------

    private fun buildConfig(args: Map<String, Any>): Config {
        Log.d(TAG, "بناء إعدادات WireGuard...")

        fun req(key: String): String {
            val v = args[key] as? String
            if (v.isNullOrBlank()) throw IllegalArgumentException("missing/empty: $key")
            return v.trim()
        }

        val privateKey = req("privateKey")
        val address = req("address")
        val dns = req("dns")
        val peerPublicKey = req("peerPublicKey")
        val endpoint = req("endpoint")
        val allowedIps = req("allowedIps")

        // ✅ مرن مع Int / Long / Double / String
        val keepalive: Int = when (val v = args["persistentKeepalive"]) {
            is Int -> v
            is Long -> v.toInt()
            is Double -> v.toInt()
            is String -> v.toIntOrNull()
                ?: throw IllegalArgumentException("invalid keepalive: $v")
            null -> throw IllegalArgumentException("missing: persistentKeepalive")
            else -> throw IllegalArgumentException("unexpected keepalive type: ${v::class}")
        }

        // ✅ MTU (كان مفقوداً — افتراضي 1280 إن لم يُمرر)
        val mtu: Int = when (val v = args["mtu"]) {
            is Int -> v
            is Long -> v.toInt()
            is Double -> v.toInt()
            is String -> v.toIntOrNull() ?: 1280
            null -> 1280
            else -> 1280
        }

        Log.d(TAG, "Address: $address")
        Log.d(TAG, "DNS: $dns")
        Log.d(TAG, "Endpoint: $endpoint")
        Log.d(TAG, "AllowedIPs: $allowedIps")
        Log.d(TAG, "Keepalive: $keepalive")
        Log.d(TAG, "MTU: $mtu")

        val iface = com.wireguard.config.Interface.Builder()
            .parsePrivateKey(privateKey)
            .parseAddresses(address)
            .parseDnsServers(dns)
            .parseMtu(mtu.toString())
            .build()

        val peer = com.wireguard.config.Peer.Builder()
            .parsePublicKey(peerPublicKey)
            .parseEndpoint(endpoint)
            .parseAllowedIPs(allowedIps)
            .parsePersistentKeepalive(keepalive.toString())
            .build()

        return Config.Builder().setInterface(iface).addPeer(peer).build()
    }

    // ------------------------------------------------------------------
    // Notification
    // ------------------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "VPN Status", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "حالة اتصال VPN"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
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
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun startForegroundSafe(n: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIF_ID,
                    n,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Throwable) {
            NotificationErrorLogger.log(this, "startForegroundSafe", e, "sdk=${Build.VERSION.SDK_INT}")
            throw e
        }
    }

    private fun updateNotification(text: String) {
        try {
            // 1) فحص صلاحية POST_NOTIFICATIONS على Android 13+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val granted = ContextCompat.checkSelfPermission(
                    this, Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
                if (!granted) {
                    Log.w(TAG, "POST_NOTIFICATIONS not granted!")
                    NotificationErrorLogger.log(
                        this, "updateNotification/permission", null,
                        "POST_NOTIFICATIONS not granted"
                    )
                    try {
                        VpnStateBus.emit("error", "صلاحية الإشعارات ممنوعة! اذهب لإعدادات الهاتف واسمح بها.")
                    } catch (_: Throwable) {}
                    return
                }
            }

            // 2) التحديث عبر notify() بدلاً من startForeground()
            Log.d(TAG, "تحديث الإشعار إلى: $text")
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))

        } catch (e: Throwable) {
            Log.e(TAG, "فشل تحديث الإشعار", e)
            NotificationErrorLogger.log(this, "updateNotification", e, "text=$text")
            try { VpnStateBus.emit("error", "فشل تحديث الإشعار: ${e.message}") } catch (_: Throwable) {}
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Throwable) {
            NotificationErrorLogger.log(this, "stopForegroundCompat", e)
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
        try {
            when (newState) {
                Tunnel.State.UP ->
                    VpnStateBus.emit("connected", null, configName)
                Tunnel.State.DOWN ->
                    VpnStateBus.emit("disconnected", null)
                Tunnel.State.TOGGLE -> { /* غير مستخدم */ }
            }
        } catch (_: Throwable) {}
    }

    var state: Tunnel.State
        get() = _state
        set(v) { _state = v }
}
