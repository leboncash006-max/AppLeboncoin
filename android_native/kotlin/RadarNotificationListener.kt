package fr.eddybonnet.mpb_check

import android.app.Notification
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Écoute les notifications Leboncoin. Seul le type choisi comme déclencheur
 * (par défaut « De nouveaux résultats sont disponibles », ou celui choisi dans le
 * test global) lance le radar puis est retiré. Les autres (messages, offres…)
 * sont seulement gardées dans la liste « dernières notifications » pour le choix,
 * jamais retirées ni analysées.
 */
class RadarNotificationListener : NotificationListenerService() {
    companion object {
        @Volatile
        var instance: RadarNotificationListener? = null

        /** Notifications Leboncoin affichées en ce moment (JSON). */
        fun activeLeboncoin(): String {
            val out = JSONArray()
            val l = instance ?: return out.toString()
            try {
                for (sbn in l.activeNotifications ?: emptyArray()) {
                    if (!sbn.packageName.lowercase().contains("leboncoin")) continue
                    val (title, text, channel) = read(sbn)
                    out.put(
                        JSONObject().put("title", title).put("text", text).put("channel", channel)
                            .put("pkg", sbn.packageName).put("ts", sbn.postTime).put("active", true)
                    )
                }
            } catch (_: Exception) {
            }
            return out.toString()
        }

        private fun read(sbn: StatusBarNotification): Triple<String, String, String> {
            val n = sbn.notification
            val ex = n?.extras
            val title = ex?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
            val text = ex?.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
            val channel = if (Build.VERSION.SDK_INT >= 26) n?.channelId ?: "" else ""
            return Triple(title, text, channel)
        }
    }

    override fun onListenerConnected() {
        instance = this
        RadarEvents.setLong(this, "listener_connected", System.currentTimeMillis())
        RadarEvents.setString(this, "watchdog_problem", null) // de nouveau branché
    }

    override fun onListenerDisconnected() {
        instance = null
        RadarEvents.setLong(this, "listener_disconnected", System.currentTimeMillis())
        // débranché par le système : on demande tout de suite à être rebranché
        RadarWatchdog.rebind(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        val pkg = n.packageName ?: return
        if (!pkg.lowercase().contains("leboncoin")) return
        val notif = n.notification ?: return
        if (notif.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val (title, text, channel) = read(n)
        if (RadarEvents.firstPackage(this) == null) {
            Log.i("MpbRadar", "Première notification Leboncoin, package : $pkg")
        }
        RadarEvents.rememberPackage(this, pkg)
        RadarEvents.addRecent(this, title, text, channel, pkg)
        if (!RadarEvents.isTrigger(this, text, channel)) return // pas le déclencheur : ignorée

        RadarEvents.add(this, "notif", title, text, pkg)
        if (!RadarEvents.isEnabled(this)) return
        // retirée une fois prise en compte, pour pouvoir réapparaître normalement
        try {
            cancelNotification(n.key)
        } catch (e: Exception) {
            Log.w("MpbRadar", "Impossible de retirer la notification : $e")
        }
        RadarService.start(this)
    }
}
