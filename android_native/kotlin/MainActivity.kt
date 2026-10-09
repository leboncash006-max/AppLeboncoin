package fr.eddybonnet.mpb_check

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var radar: MethodChannel? = null
    private var browser: HeadlessBrowser? = null
    private var launch: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureLaunch(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (captureLaunch(intent)) radar?.invokeMethod("launch", null)
    }

    /** Ouverture depuis une notification du radar (analyse ou vérification). */
    private fun captureLaunch(i: Intent?): Boolean {
        val keys = listOf("open_analysis", "radar_verify", "radar_setup", "contact", "confirm_send", "messages")
        val key = keys.firstOrNull { i?.getStringExtra(it) != null } ?: return false
        launch = mapOf(key to i!!.getStringExtra(key)!!)
        keys.forEach { i.removeExtra(it) }
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val b = HeadlessBrowser(applicationContext)
        browser = b
        MethodChannel(messenger, "mpb_check/browser").setMethodCallHandler(b)
        // chien de garde (toutes les 15 min), programmé juste après le lancement ;
        // une erreur ici ne doit jamais empêcher l'appli de s'ouvrir
        android.os.Handler(mainLooper).postDelayed({
            try {
                RadarWatchdog.schedule(applicationContext)
            } catch (e: Throwable) {
                android.util.Log.e("MpbRadar", "Chien de garde non programmé", e)
                RadarEvents.setString(applicationContext, "watchdog_error", e.toString())
            }
        }, 3000)
        val ch = MethodChannel(messenger, "mpb_check/radar")
        radar = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    result.success(
                        mapOf(
                            "notificationAccess" to NotificationManagerCompat.getEnabledListenerPackages(this)
                                .contains(packageName),
                            "batteryExempt" to (pm?.isIgnoringBatteryOptimizations(packageName) == true),
                            "notificationsAllowed" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
                            "enabled" to RadarEvents.isEnabled(this),
                            "backgroundRestricted" to RadarWatchdog.backgroundRestricted(this),
                            "listenerConnected" to RadarWatchdog.listenerConnected(),
                            "watchdogLast" to RadarEvents.getLong(this, "watchdog_last"),
                            "listenerConnectedAt" to RadarEvents.getLong(this, "listener_connected"),
                            "problem" to RadarWatchdog.problem(this),
                            "firstPackage" to RadarEvents.firstPackage(this),
                            "pendingEvents" to RadarEvents.hasPending(this)
                        )
                    )
                }
                "openNotificationAccess" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                "requestBatteryExempt" -> {
                    try {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                        )
                    } catch (_: Exception) {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    }
                    result.success(null)
                }
                "openAppSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                    )
                    result.success(null)
                }
                "rebind" -> {
                    RadarWatchdog.rebind(this)
                    result.success(null)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4200)
                    }
                    result.success(null)
                }
                "setEnabled" -> {
                    RadarEvents.setEnabled(this, call.argument<Boolean>("on") ?: true)
                    result.success(null)
                }
                "setPeriodic" -> {
                    try {
                        RadarWorker.schedule(this, call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("work", e.toString(), null)
                    }
                }
                "start" -> {
                    RadarEvents.add(this, call.argument<String>("kind") ?: "manual")
                    RadarService.start(this)
                    result.success(null)
                }
                "takeEvents" -> result.success(RadarEvents.drain(this))
                "flushCookies" -> {
                    android.webkit.CookieManager.getInstance().flush()
                    result.success(null)
                }
                "lastCrash" -> result.success(CrashCatcherProvider.takeLast(this))
                "watchdogError" -> result.success(RadarEvents.getString(this, "watchdog_error"))
                "recentNotifs" -> result.success(
                    mapOf("recent" to RadarEvents.recent(this), "active" to RadarNotificationListener.activeLeboncoin())
                )
                "getTrigger" -> result.success(RadarEvents.trigger(this))
                "setTrigger" -> {
                    RadarEvents.setTrigger(this, call.argument<String>("text"), call.argument<String>("channel"))
                    result.success(null)
                }
                "takeLaunch" -> {
                    result.success(launch)
                    launch = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        browser?.disposeAll()
        super.onDestroy()
    }
}
