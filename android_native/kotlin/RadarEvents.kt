package fr.eddybonnet.mpb_check

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** File d'événements du radar (notifications Leboncoin, relances), lue par Dart. */
object RadarEvents {
    private const val PREFS = "mpb_radar_native"
    private const val KEY = "events"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun add(ctx: Context, kind: String, title: String = "", text: String = "", pkg: String = "") {
        val list = JSONArray(prefs(ctx).getString(KEY, "[]"))
        list.put(
            JSONObject()
                .put("kind", kind)
                .put("title", title)
                .put("text", text)
                .put("pkg", pkg)
                .put("ts", System.currentTimeMillis())
        )
        // garde au plus 200 événements (sécurité)
        val trimmed = JSONArray()
        val from = maxOf(0, list.length() - 200)
        for (i in from until list.length()) trimmed.put(list.get(i))
        prefs(ctx).edit().putString(KEY, trimmed.toString()).apply()
    }

    /** Rend tous les événements en attente (JSON) et vide la file. */
    @Synchronized
    fun drain(ctx: Context): String {
        val s = prefs(ctx).getString(KEY, "[]") ?: "[]"
        prefs(ctx).edit().putString(KEY, "[]").apply()
        return s
    }

    @Synchronized
    fun hasPending(ctx: Context): Boolean =
        JSONArray(prefs(ctx).getString(KEY, "[]")).length() > 0

    fun isEnabled(ctx: Context) = prefs(ctx).getBoolean("enabled", true)
    fun setEnabled(ctx: Context, v: Boolean) = prefs(ctx).edit().putBoolean("enabled", v).apply()

    fun firstPackage(ctx: Context): String? = prefs(ctx).getString("first_pkg", null)
    fun rememberPackage(ctx: Context, pkg: String) {
        if (firstPackage(ctx) == null) prefs(ctx).edit().putString("first_pkg", pkg).apply()
    }
}
