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
import androidx.activity.result.contract.ActivityResultContracts
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
    }

    // نتائج معلّقة
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotifResult: MethodChannel.Result? = null

    // sink محلي (مرآة لـ VpnStateBus.sink)
    private var eventSink: EventChannel.EventSink? = null

    // ✅ لطلب صلاحية VPN (بديل startActivityForResult المهجور)
    private val vpnPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val granted = result.resultCode == Activity.RESULT_OK
        Log.d(TAG, "VPN permission result: granted=$granted")
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    // ✅ لطلب صلاحية POST_NOTIFICATIONS (Android 13+)
    private val notificationPermLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.d(TAG, "POST_NOTIFICATIONS granted=$granted")
        pendingNotifResult?.success(granted)
        pendingNotifResult = null
    }

    // ------------------------------------------------------------------
    // Engine setup
    // ------------------------------------------------------------------

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        Log.d(TAG, "configureFlutterEngine")

        // ------------------------- MethodChannel -------------------------
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
                            VpnStateBus.emit("disconnecting", null)
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
                    VpnStateBus.emit("error", e.message ?: e.toString())
                    result.error("METHOD_ERROR", e.message, null)
                }
            }

        // ------------------------- EventChannel -------------------------
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    Log.d(TAG, "EventChannel onListen")
                    eventSink = sink
                    VpnStateBus.sink = sink
                    // أرسل الحالة الحالية فوراً كي لا تبقى الواجهة عالقة
                    sink?.success(VpnStateBus.snapshot())
                }

                override fun onCancel(args: Any?) {
                    Log.d(TAG, "EventChannel onCancel")
                    eventSink = null
                    VpnStateBus.sink = null
                }
            })
    }

    override fun onDestroy() {
        Log.d(TAG, "MainActivity.onDestroy")
        eventSink = null
        // لا نُفرّغ VpnStateBus.sink هنا لأن الخدمة قد تستمر
        super.onDestroy()
    }

    // ============================================================
    // Handlers
    // ============================================================

    // ------------------------- prepare -------------------------

    private fun handlePrepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            Log.d(TAG, "VPN permission already granted")
            result.success(true)
            return
        }
        Log.d(TAG, "requesting VPN permission via launcher")
        if (pendingPermissionResult != null) {
            Log.w(TAG, "prepare called while another permission request is pending")
            result.error("BUSY", "permission request already in flight", null)
            return
        }
        pendingPermissionResult = result
        try {
            vpnPermissionLauncher.launch(intent)
        } catch (e: Exception) {
            Log.e(TAG, "failed to launch permission intent", e)
            pendingPermissionResult = null
            result.error("PERMISSION_LAUNCH_FAILED", e.message, null)
        }
    }

    // ------------------------- connect -------------------------

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any>
        if (args == null) {
            Log.e(TAG, "connect called without args map")
            result.error("BAD_ARGS", "connect requires a map", null)
            return
        }
        Log.d(TAG, "connect args keys=${args.keys}")

        // تحقق سريع من الصلاحية قبل بدء الخدمة
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            Log.w(TAG, "connect called without VPN permission")
            result.error("NO_PERMISSION", "VPN permission not granted", null)
            return
        }

        try {
            VpnStateBus.emit("connecting", null)
            MyVpnService.start(this, args)
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "MyVpnService.start failed", e)
            VpnStateBus.emit("error", e.message ?: e.toString())
            result.error("START_FAILED", e.message, null)
        }
    }

    // ------------------------- POST_NOTIFICATIONS -------------------------

    private fun handleRequestNotification(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // لا حاجة قبل Android 13
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
            notificationPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } catch (e: Exception) {
            Log.e(TAG, "failed to launch notification permission", e)
            pendingNotifResult = null
            result.error("NOTIF_LAUNCH_FAILED", e.message, null)
        }
    }

    // ------------------------- Always-On -------------------------

    private fun handleOpenAlwaysOn(result: MethodChannel.Result) {
        // المحاولة الأولى: شاشة Always-On المخصصة
        try {
            startActivity(Intent("android.net.vpn.SETTINGS"))
            result.success(true)
            return
        } catch (e: Exception) {
            Log.w(TAG, "android.net.vpn.SETTINGS not available: ${e.message}")
        }
        // الاحتياطي: شاشة إعدادات VPN العامة
        try {
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Settings.ACTION_VPN_SETTINGS not available", e)
            result.success(false)
        }
    }

    // ------------------------- Battery optimization -------------------------

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
            result.success(false)
        }
    }
}
