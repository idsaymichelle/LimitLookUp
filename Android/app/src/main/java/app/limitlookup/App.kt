package app.limitlookup

import android.Manifest
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.webkit.CookieManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.glance.appwidget.updateAll
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Lang.loader = { code -> runCatching { assets.open("strings/$code.json").bufferedReader().readText() }.getOrNull() }
        Lang.set(Settings.language)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(Notifier.CHANNEL, "Limits", NotificationManager.IMPORTANCE_DEFAULT))
        RefreshWorker.schedule(this)
    }
}

/** Only percentages, dates and names are stored, never cookies or tokens (those live in each WebView profile). */
object Store {
    lateinit var ctx: Context
    lateinit var prefs: SharedPreferences
    private val historyFile get() = File(ctx.filesDir, "history.json")

    fun init(c: Context) { ctx = c.applicationContext; prefs = ctx.getSharedPreferences("llu", Context.MODE_PRIVATE) }
    fun usage() = Json.usage(prefs.getString("usage", null))
    fun saveUsage(u: List<ServiceUsage>) = prefs.edit().putString("usage", Json.usage(u)).apply()
    fun accounts() = Json.accounts(prefs.getString("accounts", null))
    fun saveAccounts(a: List<Account>) = prefs.edit().putString("accounts", Json.accounts(a)).apply()
    fun history() = Json.samples(runCatching { historyFile.readText() }.getOrNull())
    fun saveHistory(s: List<Sample>) {
        val tmp = File(ctx.filesDir, "history.tmp"); tmp.writeText(Json.samples(s)); tmp.renameTo(historyFile)
    }
}

/** Settings backed by SharedPreferences and observed by Compose. Same keys and defaults as on iOS. */
object Settings {
    var theme by pref("theme", "system")
    var language by pref("language", "")
    var compact by pref("compact", false)
    var showRemaining by pref("showRemaining", false)
    var showIdentity by pref("showIdentity", true)
    var threshold by pref("threshold", 80f)
    var notifyThreshold by pref("notifyThreshold", true)
    var notifyReset by pref("notifyReset", true)
    var notifyEarly by pref("notifyEarly", true)

    private fun <T> pref(key: String, def: T) = object : ReadWriteProperty<Any?, T> {
        private var state: androidx.compose.runtime.MutableState<T>? = null
        @Suppress("UNCHECKED_CAST")
        private fun s() = state ?: mutableStateOf((Store.prefs.all[key] as? T) ?: def).also { state = it }
        override fun getValue(thisRef: Any?, property: KProperty<*>) = s().value
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
            s().value = value
            Store.prefs.edit().apply {
                when (value) { is String -> putString(key, value); is Boolean -> putBoolean(key, value); is Float -> putFloat(key, value) }
            }.apply()
        }
    }

    /** After "Delete all data": defaults again. */
    fun reload() {
        theme = "system"; language = ""; compact = false; showRemaining = false; showIdentity = true
        threshold = 80f; notifyThreshold = true; notifyReset = true; notifyEarly = true
    }
}

/** Each account's cookies live in their own WebView profile, so accounts never share a session. */
object Profiles {
    val supported get() = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)

    fun cookies(a: Account): CookieManager =
        if (supported) ProfileStore.getInstance().getOrCreateProfile(a.profile).cookieManager else CookieManager.getInstance()

    fun attach(w: android.webkit.WebView, a: Account) {
        // shortcut: without MULTI_PROFILE (WebView < 121) all accounts share one cookie jar; such devices are rare now.
        if (supported) { ProfileStore.getInstance().getOrCreateProfile(a.profile); androidx.webkit.WebViewCompat.setProfile(w, a.profile) }
    }

    fun delete(a: Account) {
        if (supported) runCatching { ProfileStore.getInstance().deleteProfile(a.profile) }
            .onFailure { cookies(a).removeAllCookies(null) } // still in use by a WebView: at least drop the session
        else CookieManager.getInstance().removeAllCookies(null)
    }
}

object AppModel {
    var usage by mutableStateOf(Store.usage())
    var history by mutableStateOf(Store.history())
    var accounts by mutableStateOf(Store.accounts())
        private set
    var loading by mutableStateOf(false)
        private set
    /** Sample numbers for screenshots: debug builds only, `adb shell am start -n app.limitlookup/.MainActivity --ez demo true`. */
    var demo by mutableStateOf(false)
    private val lock = Mutex()

    private fun storeAccounts(a: List<Account>) { accounts = a; Store.saveAccounts(a) }

    /** New accounts of a service already present get the smallest free number. */
    fun addAccount(s: Service): Account {
        val taken = accounts.filter { it.service == s }.map { it.label?.toIntOrNull() ?: if (it.label == null) 1 else 0 }.toSet()
        val n = generateSequence(1) { it + 1 }.first { it !in taken }
        return Account(service = s, label = if (n == 1) null else "$n").also { storeAccounts(accounts + it) }
    }

    suspend fun rename(a: Account, label: String) {
        val i = accounts.indexOfFirst { it.id == a.id }.takeIf { it >= 0 } ?: return
        val old = accounts[i].title
        val updated = accounts[i].copy(label = label.trim().ifEmpty { null })
        storeAccounts(accounts.toMutableList().also { it[i] = updated })
        // History is keyed by title; move it so the chart keeps the account's past readings.
        history = history.map { if (it.account == old) it.copy(account = updated.title) else it }
        Store.saveHistory(history)
        usage = usage.map { if (it.accountId == a.id) it.copy(service = updated.title) else it }
        Store.saveUsage(usage)
        widgets()
    }

    suspend fun refresh() {
        if (demo) { loadDemo(); return }
        if (!lock.tryLock()) return
        loading = true
        try {
            val fetcher = Fetcher(Store.ctx)
            val result = mutableListOf<ServiceUsage>(); val fresh = mutableListOf<ServiceUsage>()
            for (a in accounts) {
                val r = fetcher.fetch(a)
                // A failed load must not wipe good numbers; keep the last ones with their old time.
                val last = usage.firstOrNull { it.accountId == a.id && it.error == null && it.limits.isNotEmpty() }
                if (r.temporary && last != null) result += last else { result += r; fresh += r }
            }
            // An account removed during this refresh must not come back.
            val ids = accounts.map { it.id }.toSet()
            result.retainAll { it.accountId in ids }; fresh.retainAll { it.accountId in ids }
            usage = result; Store.saveUsage(result)
            history = withContext(Dispatchers.IO) { History.record(fresh, Store.history()).also(Store::saveHistory) }
            widgets()
            Notifier.check(result)
        } finally { loading = false; lock.unlock() }
    }

    /** Waits for a running refresh, so a just-added account is included. */
    suspend fun refreshAfterLogin() { while (lock.isLocked) delay(200); refresh() }

    suspend fun logout(a: Account) {
        Profiles.delete(a)
        usage = usage.filter { it.accountId != a.id }
        storeAccounts(accounts.filter { it.id != a.id })
        history = history.filter { it.account != a.title } // its name can be reused by a new account
        Store.saveHistory(history); Store.saveUsage(usage)
        Notifier.forget(a.title)
        widgets()
    }

    /** Everything the app stored: accounts and their sign-ins, history, usage, settings. */
    suspend fun deleteAll() {
        while (lock.isLocked) delay(200) // a running refresh would write it all back
        accounts.forEach(Profiles::delete)
        storeAccounts(emptyList()); usage = emptyList(); history = emptyList()
        Store.prefs.edit().clear().commit(); Store.saveHistory(emptyList())
        Settings.reload(); Store.prefs.edit().clear().commit()
        Lang.set(null)
        WorkManager.getInstance(Store.ctx).cancelAllWorkByTag(Notifier.TAG)
        Notifier.manager().cancelAll()
        widgets()
    }

    fun clearHistory() { history = emptyList(); Store.saveHistory(emptyList()) }

    private suspend fun loadDemo() {
        val now = Instant.now()
        fun h(x: Double) = now.plusSeconds((x * 3600).toLong())
        usage = listOf(
            ServiceUsage("Claude Code", listOf(Limit("5 hours", 63.0, h(2.3), 18000.0), Limit("Week", 28.0, h(90.0), 604800.0),
                Limit("Week, Opus", 91.0, h(90.0), 604800.0), Limit("Week, Fable", 34.0, h(90.0), 604800.0)),
                now, null, "alex@example.com", "Alex Morgan", "Max 5x"),
            ServiceUsage("Claude Code 2", listOf(Limit("5 hours", 22.0, h(3.6), 18000.0), Limit("Week", 47.0, h(60.0), 604800.0)),
                now, null, "alex@company.example", "Alex Morgan"),
            ServiceUsage("Codex", listOf(Limit("5 hours", 12.0, h(4.0), 18000.0), Limit("Week", 74.0, h(51.0), 604800.0)),
                now, null, "alex@example.com", "Alex Morgan"),
        )
        Store.saveUsage(usage)
        history = History.demo(usage)
        widgets()
    }

    suspend fun widgets() = runCatching { LimitsWidget().updateAll(Store.ctx) }
}

object Notifier {
    const val CHANNEL = "limits"
    const val TAG = "llu-reset"
    fun manager(): NotificationManager = Store.ctx.getSystemService(NotificationManager::class.java)

    fun post(key: String, title: String, body: String) {
        if (ContextCompat.checkSelfPermission(Store.ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val open = android.app.PendingIntent.getActivity(Store.ctx, 0,
            android.content.Intent(Store.ctx, MainActivity::class.java), android.app.PendingIntent.FLAG_IMMUTABLE)
        manager().notify(key.hashCode(), NotificationCompat.Builder(Store.ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_monochrome).setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(open).setAutoCancel(true).build())
    }

    /** A removed account must not send a reset alert later, nor hand its "already notified" state to a new account. */
    fun forget(account: String) {
        WorkManager.getInstance(Store.ctx).cancelAllWorkByTag("account:$account")
        val mine = { k: String -> k.startsWith("notified.$account.") || k.startsWith("early.$account.") }
        val p = Store.prefs
        p.edit().putString("alertLog", Json.dates(Json.dates(p.getString("alertLog", null)).filterKeys { !mine(it) }))
            .putString("earlyReset", Json.states(Json.states(p.getString("earlyReset", null)).filterKeys { !it.startsWith("$account.") }))
            .apply()
    }

    /** One alert per limit per reset period, plus an alert when that limit resets, and one when it resets early. */
    fun check(usage: List<ServiceUsage>) {
        val p = Store.prefs
        val wm = WorkManager.getInstance(Store.ctx)
        val states = Json.states(p.getString("earlyReset", null)).toMutableMap()
        for (u in usage) for (l in u.limits) {
            val id = "${u.service}.${l.name}"
            val (notify, next) = EarlyReset.check(states[id], l)
            states[id] = next
            if (!notify || !Settings.notifyEarly) continue
            wm.cancelAllWorkByTag("reset:$id") // the reset alert for the old time is now wrong
            post("early.$id", L("%s: limit reset early", u.service), L("The “%s” limit is available again, earlier than announced.", l.title))
        }
        val sent = AlertLog.pruned(Json.dates(p.getString("alertLog", null))).toMutableMap()
        if (Settings.notifyThreshold) for (u in usage) for (l in u.limits) {
            if (l.percent < Settings.threshold) continue
            val key = AlertLog.key(u.service, l.name, l.resetsAt)
            if (key in sent) continue
            sent[key] = l.resetsAt ?: Instant.now().plusSeconds(86400)
            val pct = l.percent.toInt()
            post(key, L("%s: limit almost used up", u.service),
                l.resetsAt?.let { L("“%s”: %d%% used. Resets at %s.", l.title, pct, Lang.time(it)) } ?: L("“%s”: %d%% used.", l.title, pct))
            val reset = l.resetsAt
            if (reset != null && reset > Instant.now() && Settings.notifyReset) {
                wm.enqueueUniqueWork(key + ".reset", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<ResetWorker>()
                    .setInitialDelay(Duration.between(Instant.now(), reset).toMillis(), TimeUnit.MILLISECONDS)
                    .setInputData(workDataOf("key" to key, "service" to u.service, "limit" to l.title))
                    .addTag(TAG).addTag("account:${u.service}").addTag("reset:${u.service}.${l.name}").build())
            }
        }
        p.edit().putString("earlyReset", Json.states(states)).putString("alertLog", Json.dates(sent)).apply()
    }
}

/** "Limit reset" alert at the announced reset time. */
class ResetWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        Store.init(applicationContext)
        val d = inputData
        Notifier.post(d.getString("key") + ".reset", L("%s: limit reset", d.getString("service") ?: ""),
            L("The “%s” limit is available again.", d.getString("limit") ?: ""))
        return Result.success()
    }
}

/** Background refresh, about every 30 minutes when online (Android decides the exact time). */
class RefreshWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        withContext(Dispatchers.Main) { AppModel.refresh() }
        return Result.success()
    }

    companion object {
        fun schedule(c: Context) = WorkManager.getInstance(c).enqueueUniquePeriodicWork("refresh", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<RefreshWorker>(30, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
    }
}
