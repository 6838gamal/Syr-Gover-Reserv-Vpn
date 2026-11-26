package gamalsolutions.syria.syrgovervpn

import android.app.Application
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

class MyVpnApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Log.d("VPN_TAG", "MyVpnApp.onCreate")

        // تهيئة VpnStateBus في أسرع وقت ممكن
        try {
            VpnStateBus.init(this)
        } catch (e: Throwable) {
            Log.w("VPN_TAG", "VpnStateBus.init failed: ${e.message}")
        }

        // تتبع foreground/background بدقة عبر ProcessLifecycleOwner
        try {
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                object : DefaultLifecycleObserver {
                    override fun onStart(owner: LifecycleOwner) {
                        Log.d("VPN_TAG", "AppLifecycle → foreground")
                        AppLifecycle.onForeground()
                    }
                    override fun onStop(owner: LifecycleOwner) {
                        Log.d("VPN_TAG", "AppLifecycle → background")
                        AppLifecycle.onBackground()
                    }
                }
            )
        } catch (e: Throwable) {
            Log.w("VPN_TAG", "ProcessLifecycleOwner observer failed: ${e.message}")
        }
    }
}
