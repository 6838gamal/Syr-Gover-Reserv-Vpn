package gamalsolutions.syria.syrgovervpn

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject

object ConfigPersistence {

    private const val TAG = "VPN_TAG"
    private const val PREFS_ENCRYPTED = "vpn_prefs_encrypted"
    private const val PREFS_PLAIN = "vpn_prefs_plain"
    private const val KEY_LAST = "last_config"
    private const val KEY_AUTOSTART = "autostart"

    @Volatile private var cachedEncrypted: SharedPreferences? = null
    @Volatile private var cachedPlain: SharedPreferences? = null

    private fun encryptedPrefs(ctx: Context): SharedPreferences {
        cachedEncrypted?.let { return it }
        synchronized(this) {
            cachedEncrypted?.let { return it }
            val masterKey = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val p = EncryptedSharedPreferences.create(
                ctx,
                PREFS_ENCRYPTED,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            cachedEncrypted = p
            return p
        }
    }

    /// ✅ prefs عادية — تعمل دائماً، حتى قبل فتح القفل
    private fun plainPrefs(ctx: Context): SharedPreferences {
        cachedPlain?.let { return it }
        synchronized(this) {
            cachedPlain?.let { return it }
            val p = ctx.getSharedPreferences(PREFS_PLAIN, Context.MODE_PRIVATE)
            cachedPlain = p
            return p
        }
    }

    private fun safeEncryptedPrefs(ctx: Context): SharedPreferences {
        return try {
            encryptedPrefs(ctx)
        } catch (e: Throwable) {
            Log.e(TAG, "EncryptedSharedPreferences failed, falling back to plain prefs", e)
            NotificationErrorLogger.log(
                ctx, "ConfigPersistence/safeEncryptedPrefs", e,
                "fallback to plain prefs for encrypted data"
            )
            ctx.getSharedPreferences("${PREFS_ENCRYPTED}_plain", Context.MODE_PRIVATE)
        }
    }

    // ------------------------------------------------------------------
    // حفظ / تحميل آخر إعداد (يبقى مشفراً)
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
            safeEncryptedPrefs(ctx).edit().putString(KEY_LAST, json.toString()).apply()
            Log.d(TAG, "saveLastConfig (encrypted): keys=${args.keys}")
        } catch (e: Exception) {
            Log.e(TAG, "saveLastConfig failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/saveLastConfig", e)
        }
    }

    fun loadLastConfig(ctx: Context): Map<String, Any>? {
        return try {
            val raw = safeEncryptedPrefs(ctx).getString(KEY_LAST, null) ?: return null
            val json = JSONObject(raw)
            val map = mutableMapOf<String, Any>()
            json.keys().forEach { k ->
                when (val v = json.get(k)) {
                    is Int -> map[k] = v
                    is Long -> map[k] = v
                    is Boolean -> map[k] = v
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
            safeEncryptedPrefs(ctx).edit().remove(KEY_LAST).apply()
            Log.d(TAG, "clearLastConfig done")
        } catch (e: Exception) {
            Log.e(TAG, "clearLastConfig failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/clearLastConfig", e)
        }
    }

    // ------------------------------------------------------------------
    // Auto-start (✅ الآن في plain prefs — لا يفشل عند Boot)
    // ------------------------------------------------------------------

    fun setAutostart(ctx: Context, enabled: Boolean) {
        try {
            plainPrefs(ctx).edit().putBoolean(KEY_AUTOSTART, enabled).apply()
            Log.d(TAG, "setAutostart: $enabled (plain)")
        } catch (e: Exception) {
            Log.e(TAG, "setAutostart failed", e)
            NotificationErrorLogger.log(ctx, "ConfigPersistence/setAutostart", e)
        }
    }

    fun isAutostartEnabled(ctx: Context): Boolean {
        return try {
            plainPrefs(ctx).getBoolean(KEY_AUTOSTART, false)
        } catch (e: Exception) {
            Log.e(TAG, "isAutostartEnabled failed", e)
            false
        }
    }
}
