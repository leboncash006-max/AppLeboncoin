package fr.eddybonnet.mpb_check

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * Écoute les notifications Leboncoin (« De nouveaux résultats sont disponibles »).
 * Elles ne contiennent aucune annonce : ce n'est que le déclencheur du radar.
 */
class RadarNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        val pkg = n.packageName ?: return
        if (!pkg.lowercase().contains("leboncoin")) return
        val notif = n.notification ?: return
        if (notif.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notif.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        if (RadarEvents.firstPackage(this) == null) {
            Log.i("MpbRadar", "Première notification Leboncoin, package : $pkg")
        }
        RadarEvents.rememberPackage(this, pkg)
        RadarEvents.add(this, "notif", title, text, pkg)
        // Notification de recherche enregistrée (« De nouveaux résultats sont
        // disponibles ») : on la retire une fois prise en compte, pour qu'elle
        // puisse réapparaître normalement aux prochaines annonces. Les autres
        // notifications Leboncoin (messages…) ne sont pas touchées.
        if (isSearchAlert(text) && RadarEvents.isEnabled(this)) {
            try {
                cancelNotification(n.key)
            } catch (e: Exception) {
                Log.w("MpbRadar", "Impossible de retirer la notification : $e")
            }
        }
        if (RadarEvents.isEnabled(this)) RadarService.start(this)
    }

    private fun isSearchAlert(text: String): Boolean {
        val t = text.lowercase()
        return t.contains("nouveaux résultats") || t.contains("nouveaux resultats") ||
            t.contains("nouvelles annonces") || t.contains("nouvelle annonce")
    }
}
