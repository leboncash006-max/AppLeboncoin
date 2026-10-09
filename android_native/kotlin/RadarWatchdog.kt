package fr.eddybonnet.mpb_check

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Chien de garde du radar (toutes les 15 min, le minimum d'Android) : vérifie
 * que l'écouteur de notifications est toujours branché et que rien ne bloque
 * l'arrière-plan. Sinon, tente de rebrancher l'écouteur puis prévient par une
 * notification « Radar arrêté » (une seule fois par problème).
 */
class RadarWatchdog(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val ctx = applicationContext
        RadarEvents.setLong(ctx, "watchdog_last", System.currentTimeMillis())
        if (!RadarEvents.isEnabled(ctx)) return Result.success()
        var problem = problem(ctx)
        if (problem == "listener") {
            // écouteur débranché par le système : on demande à Android de le rebrancher
            rebind(ctx)
            Thread.sleep(8000)
            problem = problem(ctx)
        }
        val last = RadarEvents.getString(ctx, "watchdog_problem")
        if (problem != null && problem != last) {
            val (title, text) = message(problem)
            RadarNotifs.problem(ctx, title, text)
        }
        RadarEvents.setString(ctx, "watchdog_problem", problem)
        return Result.success()
    }

    companion object {
        private const val NAME = "mpb_radar_watchdog"

        fun schedule(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<RadarWatchdog>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        }

        fun rebind(ctx: Context) {
            if (Build.VERSION.SDK_INT >= 24) {
                try {
                    NotificationListenerService.requestRebind(ComponentName(ctx, RadarNotificationListener::class.java))
                } catch (_: Exception) {
                }
            }
        }

        fun accessGranted(ctx: Context) =
            NotificationManagerCompat.getEnabledListenerPackages(ctx).contains(ctx.packageName)

        fun batteryExempt(ctx: Context): Boolean =
            ctx.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(ctx.packageName) == true

        /** « Restreindre l'utilisation en arrière-plan » activé par l'utilisateur ou le système. */
        fun backgroundRestricted(ctx: Context): Boolean =
            Build.VERSION.SDK_INT >= 28 &&
                ctx.getSystemService(ActivityManager::class.java)?.isBackgroundRestricted == true

        fun listenerConnected() = RadarNotificationListener.instance != null

        /** Problème empêchant le radar de marcher, ou null si tout va bien. */
        fun problem(ctx: Context): String? = when {
            !accessGranted(ctx) -> "access"
            backgroundRestricted(ctx) -> "restricted"
            !batteryExempt(ctx) -> "battery"
            !listenerConnected() -> "listener"
            else -> null
        }

        fun message(problem: String): Pair<String, String> = when (problem) {
            "access" -> "Radar arrêté : accès aux notifications retiré" to
                "Le radar ne peut plus lire les notifications Leboncoin. Appuie pour le réactiver."
            "restricted" -> "Radar arrêté : arrière-plan bloqué" to
                "Android restreint MPB Check en arrière-plan. Mets la batterie sur « Non restreinte »."
            "battery" -> "Radar menacé : optimisation de batterie activée" to
                "Android peut couper le radar. Désactive l'optimisation de batterie pour MPB Check."
            "listener" -> "Radar arrêté : écoute des notifications coupée" to
                "Android a débranché le radar. Appuie pour ouvrir l'appli et le relancer."
            "start" -> "Radar bloqué : démarrage refusé" to
                "Android a refusé de lancer l'analyse en arrière-plan. Vérifie la batterie (non restreinte)."
            else -> "Radar arrêté" to "Appuie pour vérifier la configuration."
        }
    }
}
