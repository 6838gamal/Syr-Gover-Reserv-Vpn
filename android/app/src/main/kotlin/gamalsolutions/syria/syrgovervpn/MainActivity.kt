package com.example.myvpn

import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val REQUEST_VPN = 1001
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)

        MethodChannel(engine.dartExecutor.binaryMessenger, "com.example.myvpn/vpn")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val intent = VpnService.prepare(this)
                        if (intent == null) result.success(true)
                        else {
                            pendingResult = result
                            startActivityForResult(intent, REQUEST_VPN)
                        }
                    }
                    "connect" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any>
                        MyVpnService.start(this, args)
                        result.success(null)
                    }
                    "disconnect" -> {
                        MyVpnService.stop(this)
                        result.success(null)
                    }
                    "kick" -> {
                        MyVpnService.kick()
                        result.success(null)
                    }
                    "getAutostart" -> {
                        result.success(ConfigPersistence.isAutostartEnabled(this))
                    }
                    "setAutostart" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        ConfigPersistence.setAutostart(this, enabled)
                        result.success(null)
                    }
                    "openAlwaysOnSettings" -> {
                        try {
                            startActivity(Intent("android.net.vpn.SETTINGS"))
                            result.success(true)
                        } catch (e: Exception) {
                            // بعض الشركات تخفي هذا الإعداد — افتح إعدادات VPN العامة
                            try {
                                startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
                                startActivity(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, "com.example.myvpn/vpn_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    VpnStateBus.sink = sink
                    sink?.success(VpnStateBus.snapshot())
                }
                override fun onCancel(args: Any?) { VpnStateBus.sink = null }
            })
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN) {
            pendingResult?.success(resultCode == RESULT_OK)
            pendingResult = null
        }
    }
}
