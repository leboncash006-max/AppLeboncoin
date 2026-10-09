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

    fun setLong(ctx: Context, k: String, v: Long) = prefs(ctx).edit().putLong(k, v).apply()
    fun getLong(ctx: Context, k: String) = prefs(ctx).getLong(k, 0L)
    fun setString(ctx: Context, k: String, v: String?) = prefs(ctx).edit().putString(k, v).apply()
    fun getString(ctx: Context, k: String): String? = prefs(ctx).getString(k, null)

    fun isEnabled(ctx: Context) = prefs(ctx).getBoolean("enabled", true)
    fun setEnabled(ctx: Context, v: Boolean) = prefs(ctx).edit().putBoolean("enabled", v).apply()

    fun firstPackage(ctx: Context): String? = prefs(ctx).getString("first_pkg", null)
    fun rememberPackage(ctx: Context, pkg: String) {
        if (firstPackage(ctx) == null) prefs(ctx).edit().putString("first_pkg", pkg).apply()
    }

    // ------------------------------------------------ dernières notifs Leboncoin

    /** Dernières notifications Leboncoin (toutes), pour choisir le déclencheur. */
    @Synchronized
    fun addRecent(ctx: Context, title: String, text: String, channel: String, pkg: String) {
        val list = JSONArray(prefs(ctx).getString("recent", "[]"))
        list.put(
            JSONObject().put("title", title).put("text", text).put("channel", channel)
                .put("pkg", pkg).put("ts", System.currentTimeMillis())
        )
        val trimmed = JSONArray()
        for (i in maxOf(0, list.length() - 40) until list.length()) trimmed.put(list.get(i))
        prefs(ctx).edit().putString("recent", trimmed.toString()).apply()
    }

    fun recent(ctx: Context): String = prefs(ctx).getString("recent", "[]") ?: "[]"

    // ------------------------------------------------------------ déclencheur

    /** Déclencheur choisi : texte de la notification (+ canal Android si connu). */
    fun setTrigger(ctx: Context, text: String?, channel: String?) {
        prefs(ctx).edit().putString("trigger_text", text).putString("trigger_channel", channel).apply()
    }

    fun trigger(ctx: Context): Map<String, String?> = mapOf(
        "text" to prefs(ctx).getString("trigger_text", null),
        "channel" to prefs(ctx).getString("trigger_channel", null)
    )

    private fun norm(s: String) = java.text.Normalizer.normalize(s.lowercase(), java.text.Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "").replace(Regex("\\s+"), " ").trim()

    /**
     * La notification est-elle le déclencheur du radar ? Si un type a été choisi
     * (test global), il faut le même texte (et le même canal) ; sinon on reconnaît
     * le texte habituel « De nouveaux résultats sont disponibles ».
     */
    fun isTrigger(ctx: Context, text: String, channel: String): Boolean {
        val tText = prefs(ctx).getString("trigger_text", null)
        val tChannel = prefs(ctx).getString("trigger_channel", null)
        if (!tText.isNullOrBlank()) {
            if (!tChannel.isNullOrBlank() && channel.isNotEmpty() && channel != tChannel) return false
            return norm(text) == norm(tText) || norm(text).contains(norm(tText))
        }
        val t = norm(text)
        return t.contains("nouveaux resultats") || t.contains("nouvelles annonces") || t.contains("nouvelle annonce")
    }
}
