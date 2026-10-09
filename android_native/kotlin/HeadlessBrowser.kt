package fr.eddybonnet.mpb_check

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * WebViews Android sans affichage, pilotées depuis Dart (canal « mpb_check/browser »).
 * Les cookies sont ceux de toutes les WebViews de l'appli (CookieManager global) :
 * une vérification faite dans la WebView visible profite aussi au radar.
 *
 * Méthodes : load(tab, url, timeoutMs) → {ok, error}, eval(tab, js) → résultat JSON,
 * fetch(tab, url, headers) → {status, body} (requête faite depuis la page), dispose(tab).
 */
class HeadlessBrowser(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val views = HashMap<String, WebView>()
    private val fetches = HashMap<String, MethodChannel.Result>()
    private var nextFetch = 0

    inner class Bridge {
        @JavascriptInterface
        fun post(id: String, json: String) {
            main.post { fetches.remove(id)?.success(json) }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun view(tab: String): WebView = views.getOrPut(tab) {
        val w = WebView(context)
        w.settings.javaScriptEnabled = true
        w.settings.domStorageEnabled = true
        w.addJavascriptInterface(Bridge(), "MpbNative")
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true)
        // taille d'un écran de téléphone, même sans fenêtre
        val wSpec = View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY)
        val hSpec = View.MeasureSpec.makeMeasureSpec(2200, View.MeasureSpec.EXACTLY)
        w.measure(wSpec, hSpec)
        w.layout(0, 0, 1080, 2200)
        w
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val tab = call.argument<String>("tab") ?: "main"
        when (call.method) {
            "load" -> load(tab, call.argument<String>("url") ?: "", call.argument<Int>("timeoutMs") ?: 30000, result)
            "eval" -> view(tab).evaluateJavascript(call.argument<String>("js") ?: "null") { v -> result.success(v) }
            "fetch" -> fetch(tab, call.argument<String>("url") ?: "", call.argument<String>("headers") ?: "{}", result)
            "dispose" -> {
                views.remove(tab)?.destroy()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun load(tab: String, url: String, timeoutMs: Int, result: MethodChannel.Result) {
        val w = view(tab)
        var done = false
        fun finish(ok: Boolean, error: String?) {
            if (done) return
            done = true
            result.success(mapOf("ok" to ok, "error" to error))
        }
        w.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, u: String?, favicon: Bitmap?) {}
            override fun onPageFinished(view: WebView?, u: String?) {
                finish(true, null)
            }
            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                if (request?.isForMainFrame == true) finish(false, error?.description?.toString() ?: "erreur réseau")
            }
        }
        main.postDelayed({ finish(false, "délai dépassé") }, timeoutMs.toLong())
        w.loadUrl(url)
    }

    private fun fetch(tab: String, url: String, headersJson: String, result: MethodChannel.Result) {
        val id = "f${nextFetch++}"
        fetches[id] = result
        val js = """
            fetch(${JSONObject.quote(url)}, {headers: $headersJson, credentials: 'include'})
              .then(r => r.text().then(t => MpbNative.post('$id', JSON.stringify({status: r.status, body: t}))))
              .catch(e => MpbNative.post('$id', JSON.stringify({status: 0, body: String(e)})));
        """.trimIndent()
        view(tab).evaluateJavascript(js, null)
        main.postDelayed({
            fetches.remove(id)?.success(JSONObject().put("status", 0).put("body", "délai dépassé").toString())
        }, 20000)
    }

    fun disposeAll() {
        views.values.forEach { it.destroy() }
        views.clear()
    }
}
