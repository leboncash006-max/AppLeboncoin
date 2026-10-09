package fr.eddybonnet.mpb_check

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** Filet de sécurité (désactivé par défaut) : relance le radar toutes les 60 min. */
class RadarWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        if (!RadarEvents.isEnabled(applicationContext)) return Result.success()
        RadarEvents.add(applicationContext, "periodic")
        RadarService.start(applicationContext)
        return Result.success()
    }

    companion object {
        private const val NAME = "mpb_radar_periodic"

        fun schedule(ctx: Context, on: Boolean) {
            val wm = WorkManager.getInstance(ctx)
            if (on) {
                val req = PeriodicWorkRequestBuilder<RadarWorker>(60, TimeUnit.MINUTES).build()
                wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, req)
            } else {
                wm.cancelUniqueWork(NAME)
            }
        }
    }
}
