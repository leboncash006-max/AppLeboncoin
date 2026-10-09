package fr.eddybonnet.mpb_check

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Service de premier plan court : lance le code Dart du radar (point d'entrée
 * « radarMain ») dans un moteur Flutter sans écran, puis s'arrête quand Dart
 * a traité tous les événements.
 */
class RadarService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var browser: HeadlessBrowser? = null

    companion object {
        fun start(ctx: Context) {
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, RadarService::class.java))
            } catch (e: Exception) {
                // Android 12+ refuse le démarrage en arrière-plan si l'optimisation
                // de batterie n'est pas désactivée pour l'appli : on prévient
                Log.w("MpbRadar", "Démarrage du service refusé : $e")
                RadarEvents.setString(ctx, "watchdog_problem", "start")
                val (title, text) = RadarWatchdog.message("start")
                RadarNotifs.problem(ctx, title, text)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        RadarNotifs.channels(this)
        val notif = RadarNotifs.running(this, "Radar : démarrage…")
        try {
            ServiceCompat.startForeground(
                this, RadarNotifs.RUN_ID, notif,
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
            )
        } catch (e: Exception) {
            Log.w("MpbRadar", "startForeground impossible : $e")
            stopSelf()
            return START_NOT_STICKY
        }
        if (engine == null) startEngine() else channel?.invokeMethod("wake", null)
        return START_NOT_STICKY
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val e = FlutterEngine(applicationContext)
        val b = HeadlessBrowser(applicationContext)
        MethodChannel(e.dartExecutor.binaryMessenger, "mpb_check/browser").setMethodCallHandler(b)
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, "mpb_check/radar_bg")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeEvents" -> result.success(RadarEvents.drain(this))
                "progress" -> {
                    val text = call.argument<String>("text") ?: "Radar"
                    try {
                        NotificationManagerCompat.from(this).notify(RadarNotifs.RUN_ID, RadarNotifs.running(this, text))
                    } catch (_: SecurityException) {
                    }
                    result.success(null)
                }
                "notifyDeal" -> {
                    RadarNotifs.deal(
                        this,
                        call.argument<Int>("id") ?: 1,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("adUrl") ?: "https://www.leboncoin.fr",
                        call.argument<String>("analysisId") ?: "",
                        call.argument<Boolean>("high") ?: false
                    )
                    result.success(null)
                }
                "notifyVerify" -> {
                    RadarNotifs.verify(this, call.argument<String>("url") ?: "https://www.leboncoin.fr")
                    result.success(null)
                }
                "done" -> {
                    result.success(null)
                    // un événement arrivé entre-temps : on continue
                    if (RadarEvents.hasPending(this)) channel?.invokeMethod("wake", null) else stopSelf()
                }
                else -> result.notImplemented()
            }
        }
        engine = e
        channel = ch
        browser = b
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "radarMain")
        )
    }

    override fun onDestroy() {
        browser?.disposeAll()
        engine?.destroy()
        engine = null
        channel = null
        browser = null
        super.onDestroy()
    }

    override fun onTimeout(startId: Int) {
        // limite Android 15 pour les services « dataSync »
        stopSelf()
    }
}
