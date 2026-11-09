package app.limitlookup

import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Languages the app ships. Names are written in their own language so anyone can find theirs. */
val appLanguages = listOf(
    "en" to "English", "ru" to "Русский", "zh-Hant" to "繁體中文", "zh-Hans" to "简体中文", "es" to "Español",
    "ko" to "한국어", "ar" to "العربية", "de" to "Deutsch", "it" to "Italiano", "fr" to "Français", "ja" to "日本語",
)

/** The language chosen inside the app (null = follow the system). Tables come from assets/strings, made by scripts/android_strings.py. */
object Lang {
    var code: String? = null
        private set
    /** Reads assets/strings/<code>.json; set by the app. Tests leave it null, so English keys are used. */
    var loader: ((String) -> String?)? = null
    private var table: Map<String, String> = emptyMap()

    fun set(c: String?) {
        code = c?.ifEmpty { null }
        val tag = code ?: system()
        table = runCatching {
            val o = JSONObject(loader?.invoke(tag) ?: "{}")
            o.keys().asSequence().associateWith { o.getString(it) }
        }.getOrDefault(emptyMap())
    }

    private fun system(): String {
        val l = Locale.getDefault()
        if (l.language == "zh") return if (l.script == "Hant" || l.country in setOf("TW", "HK", "MO")) "zh-Hant" else "zh-Hans"
        return l.language
    }

    val locale: Locale get() = code?.let(Locale::forLanguageTag) ?: Locale.getDefault()

    fun lookup(key: String) = table[key] ?: key

    private fun z(d: Instant) = d.atZone(ZoneId.systemDefault())
    fun time(d: Instant): String = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(z(d))
    fun weekdayTime(d: Instant) = DateTimeFormatter.ofPattern("EEE", locale).format(z(d)) + " " + time(d)
    fun dayMonth(d: Instant): String = DateTimeFormatter.ofPattern("d MMM", locale).format(z(d))
    fun month(d: Instant): String = DateTimeFormatter.ofPattern("LLL", locale).format(z(d)).replace(".", "")
    fun decimal(x: Double) = String.format(locale, "%.1f", x)

    // ICU on the device gives unit names in the app's language ("2 ч 14 мин"); plain English in local tests.
    fun hoursMinutes(sec: Long): String {
        val h = sec / 3600; val m = sec % 3600 / 60
        return runCatching {
            val f = android.icu.text.MeasureFormat.getInstance(locale, android.icu.text.MeasureFormat.FormatWidth.NARROW)
            val parts = listOfNotNull(
                if (h > 0) android.icu.util.Measure(h, android.icu.util.MeasureUnit.HOUR) else null,
                if (m > 0 || h == 0L) android.icu.util.Measure(m, android.icu.util.MeasureUnit.MINUTE) else null)
            f.formatMeasures(*parts.toTypedArray())!!
        }.getOrElse { listOfNotNull(if (h > 0) "${h}h" else null, if (m > 0 || h == 0L) "${m}m" else null).joinToString(" ") }
    }

    fun days(n: Long): String = runCatching {
        android.icu.text.MeasureFormat.getInstance(locale, android.icu.text.MeasureFormat.FormatWidth.WIDE)
            .format(android.icu.util.Measure(n, android.icu.util.MeasureUnit.DAY))!!
    }.getOrElse { if (n == 1L) "1 day" else "$n days" }

    fun weekdayName(d: java.time.DayOfWeek): String =
        d.getDisplayName(java.time.format.TextStyle.FULL_STANDALONE, locale).replaceFirstChar { it.titlecase(locale) }
}

/** Localized string in the app's language; keys are the English source strings, as on iOS. */
fun L(key: String, vararg args: Any): String {
    val f = Lang.lookup(key)
    return if (args.isEmpty()) f else runCatching { String.format(Lang.locale, f, *args) }.getOrElse { String.format(Locale.US, key, *args) }
}

/** Read-only, same-origin requests: identical to claudeJS / codexJS in App/Fetcher.swift. */
object Scripts {
    val claude = """
    const get = async (p) => {
      const r = await fetch(p, {credentials: 'include', signal: AbortSignal.timeout(15000)});
      if (r.status === 403 && r.headers.get('cf-mitigated')) throw new Error('blocked');
      if (r.status === 401 || r.status === 403) throw new Error('auth');
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    };
    try {
      const orgs = await get('/api/organizations');
      const org = orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
      if (!org) return JSON.stringify({error: 'auth'});
      const usage = await get('/api/organizations/' + org.uuid + '/usage');
      try {
        const a = await get('/api/account');
        usage._name = a.full_name || a.display_name || a.name || null;
        usage._identity = a.email_address || a.email || null;
      } catch (_) {}
      if (!usage._name && !usage._identity) usage._name = org.name || null;
      usage._plan = org.rate_limit_tier || ((org.capabilities || []).find(c => /max|pro|team|enterprise/i.test(c))) || null;
      return JSON.stringify(usage);
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """.trimIndent()

    val codex = """
    try {
      const t = () => AbortSignal.timeout(15000);
      const sr = await fetch('/api/auth/session', {credentials: 'include', signal: t()});
      if (sr.status === 403 && sr.headers.get('cf-mitigated')) return JSON.stringify({error: 'blocked'});
      const s = await sr.json();
      if (!s.accessToken) return JSON.stringify({error: 'auth'});
      const r = await fetch('/backend-api/wham/usage', {headers: {Authorization: 'Bearer ' + s.accessToken}, signal: t()});
      if (r.status === 403 && r.headers.get('cf-mitigated')) return JSON.stringify({error: 'blocked'});
      if (r.status === 401 || r.status === 403) return JSON.stringify({error: 'auth'});
      if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
      const j = await r.json();
      j._name = (s.user && s.user.name) || null;
      j._identity = (s.user && s.user.email) || null;
      return JSON.stringify(j);
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """.trimIndent()
}
