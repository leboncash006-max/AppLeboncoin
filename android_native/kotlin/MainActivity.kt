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
        val analysis = i?.getStringExtra("open_analysis")
        val verify = i?.getStringExtra("radar_verify")
        if (analysis == null && verify == null) return false
        launch = if (analysis != null) mapOf("open_analysis" to analysis) else mapOf("radar_verify" to verify!!)
        i?.removeExtra("open_analysis")
        i?.removeExtra("radar_verify")
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val b = HeadlessBrowser(applicationContext)
        browser = b
        MethodChannel(messenger, "mpb_check/browser").setMethodCallHandler(b)
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
                    RadarWorker.schedule(this, call.argument<Boolean>("on") ?: false)
                    result.success(null)
                }
                "start" -> {
                    RadarEvents.add(this, call.argument<String>("kind") ?: "manual")
                    RadarService.start(this)
                    result.success(null)
                }
                "takeEvents" -> result.success(RadarEvents.drain(this))
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
