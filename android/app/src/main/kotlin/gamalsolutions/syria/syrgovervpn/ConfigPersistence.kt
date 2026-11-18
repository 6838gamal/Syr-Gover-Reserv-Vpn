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

    // ✅ cache thread-safe لتجنب إعادة إنشاء MasterKey في كل استدعاء
    @Volatile
    private var cachedPrefs: SharedPreferences? = null

    private fun prefs(ctx: Context): SharedPreferences {
        cachedPrefs?.let { return it }
        synchronized(this) {
            cachedPrefs?.let { return it }

            val masterKey = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val p = EncryptedSharedPreferences.create(
                ctx,
                PREFS,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            cachedPrefs = p
            return p
        }
    }

    /// prefs آمنة مع fallback إلى SharedPreferences عادية إذا فشل التشفير
    private fun safePrefs(ctx: Context): SharedPreferences {
        return try {
            prefs(ctx)
        } catch (e: Throwable) {
            Log.e(TAG, "EncryptedSharedPreferences failed, falling back to plain prefs", e)
            NotificationErrorLogger.log(
                ctx, "ConfigPersistence/safePrefs", e,
                "fallback to plain prefs"
            )
            ctx.getSharedPreferences("${PREFS}_plain", Context.MODE_PRIVATE)
        }
    }

    // ------------------------------------------------------------------
    // حفظ / تحميل آخر إعداد
    // ------------------------------------------------------------------

    fun saveLastConfig(ctx: Context, args: Map<String, Any>) {
        try {
            val json = JSONObject()
            args.forEach { (k, v) ->
                when (v) {
                    is Int -> json.put(k, v)
                    is Long -> json.put(k, v)
                    is Boolean -> json.put(k, v)
                    is Double -> json.put(k, v)
                    is Float -> json.put(k, v.toDouble())
                    is String -> json.put(k, v)
                    else -> json.put(k, v.toString())
                }
            }
            safePrefs(ctx).edit().putString(KEY_LAST, json.toString()).apply()
            Log.d(TAG, "saveLastConfig (encrypted): keys=${args.keys}")
        } catch (e: Exception) {
            Log.e(TAG, "saveLastConfig failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/saveLastConfig", e)
        }
    }

    fun loadLastConfig(ctx: Context): Map<String, Any>? {
        return try {
            val raw = safePrefs(ctx).getString(KEY_LAST, null) ?: return null
            val json = JSONObject(raw)
            val map = mutableMapOf<String, Any>()
            json.keys().forEach { k ->
                when (val v = json.get(k)) {
                    is Int -> map[k] = v
                    is Long -> map[k] = v
                    is Boolean -> map[k] = v
                    // ✅ إصلاح: Double صغير يُحفظ كـ Int عند القراءة
                    is Double ->
                        if (v == v.toLong().toDouble() &&
                            v >= Int.MIN_VALUE.toDouble() &&
                            v <= Int.MAX_VALUE.toDouble())
                            map[k] = v.toInt()
                        else map[k] = v
                    is String -> map[k] = v
                    else -> map[k] = v.toString()
                }
            }
            Log.d(TAG, "loadLastConfig: keys=${map.keys}")
            map
        } catch (e: Exception) {
            Log.e(TAG, "loadLastConfig failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/loadLastConfig", e)
            null
        }
    }

    fun clearLastConfig(ctx: Context) {
        try {
            safePrefs(ctx).edit().remove(KEY_LAST).apply()
            Log.d(TAG, "clearLastConfig done")
        } catch (e: Exception) {
            Log.e(TAG, "clearLastConfig failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/clearLastConfig", e)
        }
    }

    // ------------------------------------------------------------------
    // Auto-start
    // ------------------------------------------------------------------

    fun setAutostart(ctx: Context, enabled: Boolean) {
        try {
            safePrefs(ctx).edit().putBoolean(KEY_AUTOSTART, enabled).apply()
            Log.d(TAG, "setAutostart: $enabled")
        } catch (e: Exception) {
            Log.e(TAG, "setAutostart failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/setAutostart", e)
        }
    }

    fun isAutostartEnabled(ctx: Context): Boolean {
        return try {
            safePrefs(ctx).getBoolean(KEY_AUTOSTART, false)
        } catch (e: Exception) {
            Log.e(TAG, "isAutostartEnabled failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/isAutostartEnabled", e)
            false
        }
    }
}
