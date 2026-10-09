package fr.eddybonnet.mpb_check

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Notifications du radar : service en cours, bonnes affaires, vérification. */
object RadarNotifs {
    const val CH_RUN = "radar_run"
    const val CH_DEALS = "radar_deals"
    const val CH_ALERT = "radar_alert"
    const val RUN_ID = 4100
    private const val VERIFY_ID = 4101
    private const val PROBLEM_ID = 4102

    fun channels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(CH_RUN, "Radar en cours", NotificationManager.IMPORTANCE_MIN)
                .apply { description = "Pendant l'analyse des nouvelles annonces" })
        nm.createNotificationChannel(
            NotificationChannel(CH_DEALS, "Bonnes affaires", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Annonces rentables trouvées par le radar" })
        nm.createNotificationChannel(
            NotificationChannel(CH_ALERT, "Vérification Leboncoin", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Leboncoin demande une vérification manuelle" })
    }

    private fun flags() = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    private fun appIntent(ctx: Context, key: String, value: String, req: Int): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(key, value)
        return PendingIntent.getActivity(ctx, req, i, flags())
    }

    fun running(ctx: Context, text: String) =
        NotificationCompat.Builder(ctx, CH_RUN)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(text)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

    fun deal(ctx: Context, id: Int, title: String, text: String, adUrl: String, analysisId: String, high: Boolean) {
        channels(ctx)
        val open = appIntent(ctx, "open_analysis", analysisId, id)
        val ad = PendingIntent.getActivity(
            ctx, id + 1, Intent(Intent.ACTION_VIEW, Uri.parse(adUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), flags())
        val n = NotificationCompat.Builder(ctx, CH_DEALS)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(if (high) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setAutoCancel(true)
            .setContentIntent(open)
            .addAction(0, "Annonce", ad)
            .addAction(0, "Contacter", appIntent(ctx, "contact", analysisId, id + 2))
            .addAction(0, "Analyse", open)
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (_: SecurityException) {
        }
    }

    /** Notification d'information (messages aux vendeurs) ; appui → appli avec [key]=[value]. */
    fun info(ctx: Context, id: Int, title: String, text: String, key: String, value: String, high: Boolean) {
        channels(ctx)
        val n = NotificationCompat.Builder(ctx, if (high) CH_ALERT else CH_DEALS)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(appIntent(ctx, key, value, id))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (_: SecurityException) {
        }
    }

    /** « Radar arrêté » : appui → écran de mise en route du radar. */
    fun problem(ctx: Context, title: String, text: String) {
        channels(ctx)
        val n = NotificationCompat.Builder(ctx, CH_ALERT)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(appIntent(ctx, "radar_setup", "1", PROBLEM_ID))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(PROBLEM_ID, n)
        } catch (_: SecurityException) {
        }
    }

    fun verify(ctx: Context, url: String) {
        channels(ctx)
        val n = NotificationCompat.Builder(ctx, CH_ALERT)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle("Leboncoin demande une vérification")
            .setContentText("Radar en pause. Appuie pour faire la vérification.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(appIntent(ctx, "radar_verify", url, VERIFY_ID))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(VERIFY_ID, n)
        } catch (_: SecurityException) {
        }
    }
}
