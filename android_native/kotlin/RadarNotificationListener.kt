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

    /** Notification de messagerie Leboncoin (catégorie, canal ou style « conversation »). */
    private fun isMessage(n: Notification, channel: String): Boolean {
        if (n.category == Notification.CATEGORY_MESSAGE) return true
        val c = channel.lowercase()
        if (c.contains("messag") || c.contains("chat") || c.contains("conversation")) return true
        val ex = n.extras ?: return false
        return ex.containsKey(Notification.EXTRA_MESSAGES)
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
        if (!RadarEvents.isTrigger(this, text, channel)) {
            // message d'un vendeur ? (réponses aux annonces contactées) : jamais retirée
            if (isMessage(notif, channel)) {
                val ex = notif.extras
                val sub = listOfNotNull(
                    ex?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
                    ex?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
                    if (Build.VERSION.SDK_INT >= 28) ex?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString() else null
                ).filter { it.isNotBlank() && it != text }.joinToString(" · ")
                RadarEvents.add(this, "reply", title, if (sub.isEmpty()) text else "$text · $sub", pkg)
                RadarService.start(this)
            }
            return // pas le déclencheur : ignorée
        }

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
