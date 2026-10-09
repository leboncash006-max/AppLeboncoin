package fr.eddybonnet.mpb_check

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import kotlin.system.exitProcess

/**
 * Attrape-plantage : installé au tout début du lancement (ContentProvider),
 * il enregistre l'erreur d'un plantage Android et l'affiche dans un écran
 * séparé (processus « :crash ») avec un bouton « Copier ».
 */
class CrashCatcherProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val ctx = context?.applicationContext ?: return true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            try {
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                val version = try {
                    ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName
                } catch (_: Exception) {
                    "?"
                }
                val report = "MPB Check $version · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · " +
                    "${Build.MANUFACTURER} ${Build.MODEL}\nThread : ${thread.name}\n\n$sw"
                File(ctx.filesDir, "last_crash.txt").writeText(report)
                ctx.startActivity(
                    Intent(ctx, CrashActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        .putExtra("report", report)
                )
            } catch (_: Throwable) {
            }
            // on laisse Android terminer le processus normalement
            if (previous != null) previous.uncaughtException(thread, e) else {
                Process.killProcess(Process.myPid())
                exitProcess(10)
            }
        }
        return true
    }

    override fun query(u: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0

    companion object {
        /** Dernier plantage enregistré (lu puis effacé par l'appli). */
        fun takeLast(ctx: Context): String? {
            val f = File(ctx.filesDir, "last_crash.txt")
            if (!f.exists()) return null
            val s = f.readText()
            f.delete()
            return s
        }
    }
}

/** Écran d'erreur, sans Flutter, dans un processus séparé. */
class CrashActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val report = intent.getStringExtra("report") ?: "Erreur inconnue"
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
        }
        root.addView(TextView(this).apply {
            text = "MPB Check a planté"
            textSize = 22f
        })
        root.addView(TextView(this).apply {
            text = "Copie ce rapport et envoie-le pour que le problème soit corrigé."
            setPadding(0, pad / 2, 0, pad / 2)
        })
        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.addView(Button(this).apply {
            text = "Copier le rapport"
            setOnClickListener {
                val cm = getSystemService(ClipboardManager::class.java)
                cm?.setPrimaryClip(ClipData.newPlainText("MPB Check", report))
                text = "Copié ✓"
            }
        })
        buttons.addView(Button(this).apply {
            text = "Relancer"
            setOnClickListener {
                packageManager.getLaunchIntentForPackage(packageName)?.let {
                    startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
                }
                finish()
            }
        })
        root.addView(buttons)
        root.addView(ScrollView(this).apply {
            addView(TextView(this@CrashActivity).apply {
                text = report
                textSize = 11f
                setTextIsSelectable(true)
            })
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }
}
