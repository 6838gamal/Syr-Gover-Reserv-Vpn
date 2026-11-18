package gamalsolutions.syria.syrgovervpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "VPN_TAG"
        private const val METHOD_CHANNEL = "com.example.myvpn/vpn"
        private const val EVENT_CHANNEL = "com.example.myvpn/vpn_events"
        private const val REQUEST_VPN = 1001
        private const val REQUEST_NOTIF = 1002
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotifResult: MethodChannel.Result? = null

    // ------------------------------------------------------------------
    // Lifecycle logging
    // ------------------------------------------------------------------

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        Log.d(TAG, "MainActivity.onCreate")
        super.onCreate(savedInstanceState)
    }

    override fun onStart() { Log.d(TAG, "MainActivity.onStart"); super.onStart() }
    override fun onResume() { Log.d(TAG, "MainActivity.onResume"); super.onResume() }
    override fun onPause() { Log.d(TAG, "MainActivity.onPause"); super.onPause() }
    override fun onStop() { Log.d(TAG, "MainActivity.onStop"); super.onStop() }

    override fun onDestroy() {
        Log.d(TAG, "MainActivity.onDestroy")
        // لا حاجة لتفريغ eventSink — VpnStateBus.sink يُدار عبر EventChannel
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Engine setup
    // ------------------------------------------------------------------

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        Log.d(TAG, "configureFlutterEngine")

        // ✅ تهيئة الذاكرة لالتقاط الأخطاء (إن كانت مدعومة)
        try { VpnStateBus.init(this) } catch (e: Throwable) {
            Log.w(TAG, "VpnStateBus.init failed (ignored): ${e.message}")
        }

        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                Log.d(TAG, "method call: ${call.method} args=${call.arguments}")
                try {
                    when (call.method) {
                        "prepare" -> handlePrepare(result)
                        "connect" -> handleConnect(call, result)
                        "disconnect" -> {
                            Log.d(TAG, "disconnect requested")
                            MyVpnService.stop(this)
                            // الخدمة ستُرسل "disconnecting" و "disconnected" عبر VpnStateBus
                            result.success(null)
                        }
                        "kick" -> {
                            Log.d(TAG, "kick requested")
                            MyVpnService.kick()
                            result.success(null)
                        }
                        "isConnected" -> {
                            val running = MyVpnService.isRunning
                            Log.d(TAG, "isConnected → $running")
                            result.success(running)
                        }
                        "getState" -> {
                            val snapshot = VpnStateBus.snapshot()
                            Log.d(TAG, "getState → $snapshot")
                            result.success(snapshot)
                        }
                        "getPendingError" -> {
                            val err = VpnStateBus.consumePendingError()
                            Log.d(TAG, "getPendingError → $err")
                            result.success(err)
                        }

                        // ✅ سجل أخطاء الإشعارات
                        "getNotificationErrorLog" -> {
                            val log = NotificationErrorLogger.readAll(this)
                            Log.d(TAG, "getNotificationErrorLog length=${log.length}")
                            result.success(log)
                        }
                        "clearNotificationErrorLog" -> {
                            NotificationErrorLogger.clear(this)
                            Log.d(TAG, "clearNotificationErrorLog done")
                            result.success(true)
                        }

                        "requestNotificationPermission" ->
                            handleRequestNotification(result)
                        "getAutostart" ->
                            result.success(ConfigPersistence.isAutostartEnabled(this))
                        "setAutostart" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            ConfigPersistence.setAutostart(this, enabled)
                            result.success(null)
                        }
                        "openAlwaysOnSettings" -> handleOpenAlwaysOn(result)
                        "openBatteryOptimizationSettings" ->
                            handleBatteryOptimization(result)
                        else -> {
                            Log.w(TAG, "unknown method: ${call.method}")
                            result.notImplemented()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "method ${call.method} failed", e)
                    NotificationErrorLogger.log(this, "MethodChannel/${call.method}", e)
                    try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
                    result.error("METHOD_ERROR", e.message, null)
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    Log.d(TAG, "EventChannel onListen")
                    VpnStateBus.sink = sink
                    sink?.success(VpnStateBus.snapshot())
                }
                override fun onCancel(args: Any?) {
                    Log.d(TAG, "EventChannel onCancel")
                    VpnStateBus.sink = null
                }
            })
    }

    // ------------------------------------------------------------------
    // Permission results
    // ------------------------------------------------------------------

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN) {
            val granted = resultCode == Activity.RESULT_OK
            Log.d(TAG, "VPN permission result: granted=$granted")
            if (!granted) {
                NotificationErrorLogger.log(
                    this, "onActivityResult/REQUEST_VPN", null, "VPN permission denied"
                )
            }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIF) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            Log.d(TAG, "POST_NOTIFICATIONS granted=$granted")
            NotificationErrorLogger.log(
                this, "onRequestPermissionsResult/REQUEST_NOTIF", null,
                if (granted) "granted" else "denied by user"
            )
            pendingNotifResult?.success(granted)
            pendingNotifResult = null
        }
    }

    // ============================================================
    // Handlers
    // ============================================================

    private fun handlePrepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            Log.d(TAG, "VPN permission already granted")
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            Log.w(TAG, "prepare called while another permission request is pending")
            result.error("BUSY", "permission request already in flight", null)
            return
        }
        Log.d(TAG, "requesting VPN permission")
        pendingPermissionResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_VPN)
        } catch (e: Exception) {
            Log.e(TAG, "failed to launch permission intent", e)
            NotificationErrorLogger.log(this, "handlePrepare/startActivityForResult", e)
            pendingPermissionResult = null
            result.error("PERMISSION_LAUNCH_FAILED", e.message, null)
        }
    }

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any>
        if (args == null) {
            Log.e(TAG, "connect called without args map")
            result.error("BAD_ARGS", "connect requires a map", null)
            return
        }
        Log.d(TAG, "connect args keys=${args.keys}")

        // 1) فحص صلاحية VPN
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            Log.w(TAG, "connect called without VPN permission")
            NotificationErrorLogger.log(
                this, "handleConnect/noVpnPermission", null, "VpnService.prepare != null"
            )
            result.error("NO_PERMISSION", "VPN permission not granted", null)
            return
        }

        // 2) فحص صلاحية الإشعارات قبل بدء الخدمة (Android 13+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val notifGranted = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!notifGranted) {
                Log.w(TAG, "connect called but POST_NOTIFICATIONS not granted")
                NotificationErrorLogger.log(
                    this, "handleConnect/noNotifPermission", null, "POST_NOTIFICATIONS not granted"
                )
                result.error(
                    "NO_NOTIFICATION_PERMISSION",
                    "صلاحية الإشعارات مطلوبة لتشغيل VPN. اذهب للإعدادات واسمح بها.",
                    null
                )
                return
            }
        }

        try {
            // لا نرسل "connecting" هنا — MyVpnService.onCreate و connect يفعلان ذلك
            MyVpnService.start(this, args)
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "MyVpnService.start failed", e)
            NotificationErrorLogger.log(this, "handleConnect/MyVpnService.start", e)
            try { VpnStateBus.emit("error", e.message ?: e.toString()) } catch (_: Throwable) {}
            result.error("START_FAILED", e.message, null)
        }
    }

    private fun handleRequestNotification(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            Log.d(TAG, "POST_NOTIFICATIONS already granted")
            result.success(true)
            return
        }
        if (pendingNotifResult != null) {
            Log.w(TAG, "notification permission already in flight")
            result.error("BUSY", "notification request already in flight", null)
            return
        }
        Log.d(TAG, "requesting POST_NOTIFICATIONS")
        pendingNotifResult = result
        try {
            @Suppress("DEPRECATION")
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIF
            )
        } catch (e: Exception) {
            Log.e(TAG, "failed to launch notification permission", e)
            NotificationErrorLogger.log(this, "handleRequestNotification/requestPermissions", e)
            pendingNotifResult = null
            result.error("NOTIF_LAUNCH_FAILED", e.message, null)
        }
    }

    private fun handleOpenAlwaysOn(result: MethodChannel.Result) {
        try {
            startActivity(Intent("android.net.vpn.SETTINGS"))
            result.success(true)
            return
        } catch (e: Exception) {
            Log.w(TAG, "android.net.vpn.SETTINGS not available: ${e.message}")
        }
        try {
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Settings.ACTION_VPN_SETTINGS not available", e)
            NotificationErrorLogger.log(this, "handleOpenAlwaysOn", e)
            result.success(false)
        }
    }

    private fun handleBatteryOptimization(result: MethodChannel.Result) {
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                Log.d(TAG, "already ignoring battery optimizations")
                result.success(true)
                return
            }
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "battery optimization intent failed", e)
            NotificationErrorLogger.log(this, "handleBatteryOptimization", e)
            result.success(false)
        }
    }
}
