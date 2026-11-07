package com.example.myvpn

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * يخزّن آخر إعدادات VPN بشكل دائم لاستعادتها بعد إعادة تشغيل النظام.
 */
object ConfigPersistence {
    private const val PREFS = "vpn_prefs"
    private const val KEY_LAST = "last_config"
    private const val KEY_AUTOSTART = "autostart"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun saveLastConfig(ctx: Context, args: Map<String, Any>) {
        val json = JSONObject(args as Map<*, *>).toString()
        prefs(ctx).edit().putString(KEY_LAST, json).apply()
    }

    fun loadLastConfig(ctx: Context): Map<String, Any>? {
        val raw = prefs(ctx).getString(KEY_LAST, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val map = mutableMapOf<String, Any>()
            json.keys().forEach { k ->
                map[k] = json.get(k)
            }
            map
        } catch (_: Exception) {
            null
        }
    }

    fun setAutostart(ctx: Context, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_AUTOSTART, enabled).apply()
    }

    fun isAutostartEnabled(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_AUTOSTART, false)
}
