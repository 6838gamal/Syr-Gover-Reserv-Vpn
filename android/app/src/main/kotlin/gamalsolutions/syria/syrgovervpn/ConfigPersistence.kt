package gamalsolutions.syria.syrgovervpn

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject

object ConfigPersistence {

    private const val TAG = "VPN_TAG"
    private const val PREFS = "vpn_prefs_encrypted"
    private const val KEY_LAST = "last_config"
    private const val KEY_AUTOSTART = "autostart"

    private fun prefs(ctx: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(ctx)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            ctx,
            PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun saveLastConfig(ctx: Context, args: Map<String, Any>) {
        try {
            val json = JSONObject()
            args.forEach { (k, v) -> json.put(k, v) }
            prefs(ctx).edit().putString(KEY_LAST, json.toString()).apply()
            Log.d(TAG, "saveLastConfig (encrypted): keys=${args.keys}")
        } catch (e: Exception) {
            Log.e(TAG, "saveLastConfig failed", e)
        }
    }

    fun loadLastConfig(ctx: Context): Map<String, Any>? {
        return try {
            val raw = prefs(ctx).getString(KEY_LAST, null) ?: return null
            val json = JSONObject(raw)
            val map = mutableMapOf<String, Any>()
            json.keys().forEach { k ->
                when (val v = json.get(k)) {
                    is Int -> map[k] = v
                    is Long -> map[k] = v
                    is Boolean -> map[k] = v
                    is Double -> map[k] = v
                    is String -> map[k] = v
                    else -> map[k] = v.toString()
                }
            }
            map
        } catch (e: Exception) {
            Log.e(TAG, "loadLastConfig failed", e)
            null
        }
    }

    fun clearLastConfig(ctx: Context) {
        prefs(ctx).edit().remove(KEY_LAST).apply()
    }

    fun setAutostart(ctx: Context, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_AUTOSTART, enabled).apply()
        Log.d(TAG, "setAutostart: $enabled")
    }

    fun isAutostartEnabled(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_AUTOSTART, false)
}
