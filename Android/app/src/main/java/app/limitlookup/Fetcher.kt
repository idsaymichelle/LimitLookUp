package app.limitlookup

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * Reads limits in an invisible WebView: requests go from the service's own page with the account's cookies,
 * so the session never leaves that account's WebView profile and nothing is sent anywhere else.
 */
class Fetcher(private val ctx: Context) {
    private class LoadError(val code: Int) : Exception()

    suspend fun fetch(a: Account): ServiceUsage = withContext(Dispatchers.Main) {
        val s = a.service
        val r = try {
            load(a)
        } catch (e: TimeoutCancellationException) {
            Parse.failure(s, L("The site didn’t respond in 25 seconds. Pull down to try again.")).copy(temporary = true)
        } catch (e: LoadError) {
            val offline = e.code == WebViewClient.ERROR_HOST_LOOKUP || e.code == WebViewClient.ERROR_CONNECT
            Parse.failure(s, if (offline) L("No internet connection. Limits will update when you’re back online.")
                else L("Couldn’t get your limits. Pull down to try again.")).copy(temporary = true)
        } catch (e: org.json.JSONException) {
            Parse.failure(s, L("Couldn’t get your limits. Pull down to try again.")).copy(temporary = true)
        }
        r.copy(service = a.title, accountId = a.id)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private suspend fun load(a: Account): ServiceUsage {
        val s = a.service
        val w = WebView(ctx)
        try {
            Profiles.attach(w, a)
            w.settings.javaScriptEnabled = true
            w.settings.domStorageEnabled = true
            val loaded = CompletableDeferred<Unit>()
            val answer = CompletableDeferred<String>()
            // The reply channel exists only on the service's own origin, so no other page can post into it.
            WebViewCompat.addWebMessageListener(w, "llu", setOf("https://${s.host}")) { _, msg, _, isMainFrame, _ ->
                if (isMainFrame) answer.complete(msg.data ?: "")
            }
            w.webViewClient = object : WebViewClient() {
                override fun onPageFinished(v: WebView, url: String) { loaded.complete(Unit) }
                override fun onReceivedError(v: WebView, req: WebResourceRequest, err: WebResourceError) {
                    if (req.isForMainFrame) loaded.completeExceptionally(LoadError(err.errorCode))
                }
            }
            w.loadUrl(s.origin)
            // Without this a page that never finishes (no network, challenge loop) would hang refresh forever.
            withTimeout(25_000) { loaded.await() }
            // Never run the script on a foreign page (for example after a redirect to a login site).
            val h = w.url?.let { Uri.parse(it).host } ?: ""
            if (h != s.host && "www.$h" != s.host) return Parse.failure(s, L("Sign in to see your limits."))
            w.evaluateJavascript("(async () => { ${s.script}\n })().then(r => llu.postMessage(String(r)), e => llu.postMessage(JSON.stringify({error: String(e && e.message || e)})))", null)
            return Parse.parse(s, withTimeout(50_000) { answer.await() }) // each request has its own 15 s limit; a script error comes back as {"error": …}
        } finally {
            w.destroy()
        }
    }
}
