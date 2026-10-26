package gamalsolutions.syria.syrgovervpn

import android.content.Intent
import android.net.VpnService
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
                        val args = call.arguments as Map<String, Any>
                        MyVpnService.start(this, args)
                        result.success(null)
                    }
                    "disconnect" -> {
                        MyVpnService.stop(this)
                        result.success(null)
                    }
                    "kick" -> { MyVpnService.kick(); result.success(null) }
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
