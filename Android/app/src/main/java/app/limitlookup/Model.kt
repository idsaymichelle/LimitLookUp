package app.limitlookup

import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

// Plain Kotlin, no Android classes: the same logic as Shared/Models.swift, Shared/History.swift and Fetcher.parse,
// so it runs in local unit tests (ParseTest).

enum class Service(val title: String, val host: String, val loginUrl: String) {
    CLAUDE("Claude Code", "claude.ai", "https://claude.ai/login"),
    CODEX("Codex", "chatgpt.com", "https://chatgpt.com/auth/login");

    val origin get() = "https://$host/"
    val script get() = if (this == CLAUDE) Scripts.claude else Scripts.codex
}

/** One signed-in session. Each account gets its own WebView profile, so cookies are never shared. */
data class Account(val id: String = UUID.randomUUID().toString(), val service: Service, val label: String? = null) {
    val title get() = label?.let { "${service.title} $it" } ?: service.title
    val profile get() = "acc-$id"
}

enum class Pace { SPARE, EVEN, FAST }

data class Limit(val name: String, val percent: Double, val resetsAt: Instant?, val window: Double? = null) {
    fun elapsed(now: Instant = Instant.now()): Double? {
        val w = window?.takeIf { it > 0 } ?: return null
        val r = resetsAt ?: return null
        return (1 - secs(now, r) / w).coerceIn(0.0, 1.0)
    }

    /** Average spend per hour since the window started, in percentage points. */
    fun ratePerHour(now: Instant = Instant.now()): Double? {
        val e = elapsed(now) ?: return null
        val w = window!!
        if (e * w < 600) return null // too early to be meaningful
        return percent / (e * w / 3600)
    }

    /** A 10-point band counts as "even". */
    fun pace(now: Instant = Instant.now()): Pace? {
        val e = elapsed(now)?.takeIf { it >= 0.05 } ?: return null
        val used = percent / 100
        return if (used > e + 0.1) Pace.FAST else if (used < e - 0.1) Pace.SPARE else Pace.EVEN
    }

    /** `name` is a stable English key used for history; this is the display name. */
    val title: String get() = when {
        name.startsWith("Week, ") -> L("Week, %s", name.drop(6))
        name.startsWith("5 hours, ") -> L("5 hours") + ", " + name.drop(9)
        else -> L(name)
    }

    /** "in 2h 14m (14:30)" within a day, "in 3 days (Mon 09:00)" beyond. */
    fun resetText(now: Instant = Instant.now()): String? {
        val r = resetsAt ?: return null
        val left = secs(now, r)
        if (left <= 0) return L("now")
        if (left < 86400) return L("in %s (%s)", Lang.hoursMinutes(left.toLong()), Lang.time(r))
        return L("in %s (%s)", Lang.days((left / 86400).roundToLong()), Lang.weekdayTime(r))
    }
}

data class ServiceUsage(
    val service: String,
    val limits: List<Limit>,
    val updated: Instant,
    val error: String?,
    val identity: String? = null,
    val name: String? = null,
    val plan: String? = null,
    /** Set when the page could not be loaded (network, timeout), as opposed to a signed-out account. */
    val temporary: Boolean = false,
    val accountId: String? = null,
)

fun secs(from: Instant, to: Instant) = Duration.between(from, to).toMillis() / 1000.0

/** Detects a reset the service did before the announced time; a single low sample needs confirmation. */
object EarlyReset {
    data class State(val percent: Double, val resetsAt: Instant?, val pendingLow: Boolean = false)

    fun check(previous: State?, current: Limit, now: Instant = Instant.now()): Pair<Boolean, State> {
        val next = State(current.percent, current.resetsAt)
        val p = previous ?: return false to next
        val scheduled = p.resetsAt ?: return false to next
        if (p.percent < 20 || current.percent > 5 || now >= scheduled.minusSeconds(60)) return false to next
        val r = current.resetsAt
        if (r != null && r > scheduled.plusSeconds(60)) return true to next
        if (p.pendingLow) return true to next
        return false to State(p.percent, p.resetsAt, pendingLow = true)
    }
}

/** Remembers which "almost used up" alerts were sent, one per limit per reset window. */
object AlertLog {
    /** Reset time rounded to 10 minutes, so "resets in N seconds" drift is not a new window. */
    fun key(service: String, limit: String, resetsAt: Instant?): String {
        val t = resetsAt?.let { Math.round(it.epochSecond / 600.0) * 600 } ?: 0
        return "notified.$service.$limit.$t"
    }

    fun pruned(log: Map<String, Instant>, now: Instant = Instant.now()) = log.filterValues { it > now.minusSeconds(86400) }
}

data class Sample(val t: Instant, val account: String, val limit: String, val p: Double)

object History {
    const val KEEP = 90 * 86400L
    const val MIN_GAP = 20 * 60L

    fun record(usage: List<ServiceUsage>, old: List<Sample>, now: Instant = Instant.now()): List<Sample> {
        val all = old.filter { secs(it.t, now) < KEEP }.toMutableList()
        for (u in usage) if (u.error == null) for (l in u.limits) {
            val last = all.lastOrNull { it.account == u.service && it.limit == l.name }
            if (last != null && secs(last.t, now) < MIN_GAP && abs(last.p - l.percent) < 1) continue
            all += Sample(now, u.service, l.name, l.percent)
        }
        return all
    }

    enum class Range(val label: String, val span: Long, val bucket: Long) {
        H12("12h", 12 * 3600, 3600), H24("24h", 86400, 2 * 3600), D3("3d", 3 * 86400, 6 * 3600),
        D7("7d", 7 * 86400, 86400), D30("30d", 30 * 86400, 86400), D90("90d", 90 * 86400, 7 * 86400)
    }

    data class Bar(val start: Instant, val peak: Double)

    /** Highest reading in each bucket; empty buckets are 0 so gaps stay visible. */
    fun bars(samples: List<Sample>, account: String, limit: String, range: Range, now: Instant = Instant.now(),
             zone: ZoneId = ZoneId.systemDefault()): List<Bar> {
        val z = now.atZone(zone)
        val aligned = (if (range.bucket >= 86400) z.toLocalDate().atStartOfDay(zone) else z.truncatedTo(ChronoUnit.HOURS)).toInstant()
        val count = (range.span.toDouble() / range.bucket).roundToLong().toInt()
        val first = aligned.minusSeconds(range.bucket * (count - 1))
        val peaks = DoubleArray(count)
        for (s in samples) if (s.account == account && s.limit == limit && s.t >= first) {
            val i = (secs(first, s.t) / range.bucket).toInt()
            if (i in 0 until count) peaks[i] = max(peaks[i], s.p)
        }
        return peaks.mapIndexed { i, p -> Bar(first.plusSeconds(range.bucket * i), p) }
    }

    data class Overview(val weekPeak: Double, val daysNearLimit: Int, val activeDays: Int, val busiestWeekday: DayOfWeek?)

    fun overview(samples: List<Sample>, threshold: Double, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Overview {
        val week = samples.filter { secs(it.t, now) < 7 * 86400 }
        val days = activity(samples, 30, now, zone)
        val byWeekday = days.filterValues { it > 0 }.entries.groupBy({ it.key.dayOfWeek }, { it.value })
        return Overview(
            weekPeak = week.maxOfOrNull { it.p } ?: 0.0,
            daysNearLimit = days.values.count { it >= threshold },
            activeDays = days.values.count { it > 0 },
            busiestWeekday = byWeekday.maxByOrNull { it.value.average() }?.key,
        )
    }

    /** Per day, the highest 5-hour reading across all accounts (falls back to any limit). */
    fun activity(samples: List<Sample>, days: Int, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Map<LocalDate, Double> {
        val from = now.atZone(zone).toLocalDate().minusDays(days - 1L).atStartOfDay(zone).toInstant()
        val session = samples.filter { it.limit == "5 hours" }
        val out = mutableMapOf<LocalDate, Double>()
        for (s in session.ifEmpty { samples }) if (s.t >= from) {
            val d = s.t.atZone(zone).toLocalDate()
            out[d] = max(out[d] ?: 0.0, s.p)
        }
        return out
    }

    /** Plausible readings for demo mode and store screenshots. */
    fun demo(usage: List<ServiceUsage>, now: Instant = Instant.now()): List<Sample> {
        val out = mutableListOf<Sample>()
        var seed = 42UL
        fun rnd(): Double { seed = seed * 6364136223846793005UL + 1442695040888963407UL; return (seed shr 33).toDouble() / (1L shl 31) }
        for (u in usage) for (l in u.limits) {
            var t = now.minusSeconds(KEEP)
            while (t < now) {
                val wd = t.atZone(ZoneId.systemDefault()).dayOfWeek
                val day = t.epochSecond / 86400
                val dayLevel = ((day * 2654435761L) % 100 + 100) % 100 / 100.0
                val busy = if (wd == DayOfWeek.SATURDAY || wd == DayOfWeek.SUNDAY) 0.3 else 1.0
                out += Sample(t, u.service, l.name, min(100.0, (0.3 + 0.7 * rnd()) * 100 * busy * dayLevel))
                t = t.plusSeconds(3 * 3600)
            }
            out += Sample(now, u.service, l.name, l.percent)
        }
        return out
    }
}

object Parse {
    fun failure(s: Service, msg: String) = ServiceUsage(s.title, emptyList(), Instant.now(), msg)

    /** Same as Fetcher.parse on iOS. Throws org.json.JSONException on a non-JSON answer. */
    fun parse(s: Service, raw: String, now: Instant = Instant.now()): ServiceUsage {
        val obj = JSONObject(raw)
        obj.str("error")?.let { e ->
            val msg = when (e) {
                "auth" -> L("Sign in to see your limits.")
                "blocked" -> L("The site wants to check you’re not a robot. Open “Sign in again” and complete the check.")
                else -> L("The site returned an error (%s). Pull down to try again.", e)
            }
            return failure(s, msg)
        }
        val limits = mutableListOf<Limit>()
        if (s == Service.CLAUDE) {
            // {"five_hour": {"utilization": 12, "resets_at": "..."}, "seven_day": {...}, ...}
            // Newer: {"limits": [{"group": "weekly", "percent": 0, "resets_at": "...", "scope": {"model": {"display_name": "Fable"}}}, ...]}
            // Anthropic adds scoped limits there on its own; each becomes a row.
            obj.optJSONArray("limits")?.let { arr -> for (i in 0 until arr.length()) {
                val d = arr.optJSONObject(i) ?: continue
                val u = d.num("percent") ?: continue
                val scope = d.optJSONObject("scope")
                val label = listOf("model", "surface").firstNotNullOfOrNull { scope?.optJSONObject(it)?.str("display_name") }
                val group = d.str("group") ?: d.str("kind") ?: "limit"
                val (base, window) = when (group) { "session" -> "5 hours" to 18000.0; "weekly" -> "Week" to 604800.0; else -> claudeName(group) to null }
                limits += Limit(if (label != null) "$base, $label" else base, u, d.str("resets_at")?.let(::parseISO), window)
            } }
            // Older: {"five_hour": {"utilization": 12, "resets_at": "..."}, "seven_day": {...}, "seven_day_opus": {...}}
            if (limits.isEmpty()) for (key in obj.keys()) {
                val d = obj.opt(key) as? JSONObject ?: continue
                val u = d.num("utilization") ?: continue
                limits += Limit(claudeName(key), u, d.str("resets_at")?.let(::parseISO), claudeWindow(key))
            }
            val order = listOf("5 hours", "Week")
            limits.sortWith(compareBy({ order.indexOf(it.name).let { i -> if (i < 0) 9 else i } }, { it.name }))
        } else {
            // {"rate_limit": {"primary_window": {"used_percent": 4, "reset_at": 1762..., "limit_window_seconds": 18000}, ...}}
            val rl = obj.optJSONObject("rate_limit")
            if (rl != null) for (key in listOf("primary_window", "secondary_window")) {
                val d = rl.optJSONObject(key) ?: continue
                val u = d.num("used_percent") ?: continue
                val sec = d.num("limit_window_seconds") ?: 0.0
                val reset = d.num("reset_at")?.let { Instant.ofEpochMilli((it * 1000).toLong()) }
                    ?: d.num("reset_after_seconds")?.let { now.plusMillis((it * 1000).toLong()) }
                limits += Limit(if (sec > 0) windowName(sec) else key, u, reset, if (sec > 0) sec else null)
            }
        }
        return ServiceUsage(s.title, limits, now,
            if (limits.isEmpty()) L("The site sent no limit data. This account may not have a subscription.") else null,
            obj.str("_identity"), obj.str("_name"), obj.str("_plan")?.let(::planName))
    }

    fun windowName(sec: Double) = when {
        sec == 604800.0 -> "Week"; sec == 18000.0 -> "5 hours"
        sec >= 86400 -> "${(sec / 86400).toInt()} days"; sec >= 3600 -> "${(sec / 3600).toInt()} hours"
        else -> "${(sec / 60).toInt()} min"
    }

    /** "default_claude_max_5x" → "Max 5x". Unknown values are left out. */
    fun planName(raw: String): String? {
        val r = raw.lowercase()
        return when {
            "max" in r -> if ("20" in r) "Max 20x" else if ("5" in r) "Max 5x" else "Max"
            "pro" in r -> "Pro"; "team" in r -> "Team"; "enterprise" in r -> "Enterprise"
            else -> null
        }
    }

    /** Claude adds per-model limits on its own ("seven_day_fable", "five_hour_opus", …): each becomes its own row. */
    private val claudeBases = listOf(Triple("five_hour", "5 hours", 18000.0), Triple("seven_day", "Week", 604800.0))
    private fun words(k: String) = k.split('_').filter { it.isNotEmpty() }.joinToString(" ") { it.replaceFirstChar(Char::uppercase) }

    fun claudeName(key: String): String {
        for ((p, name) in claudeBases) {
            if (key == p) return name
            if (key.startsWith(p + "_")) return name + ", " + words(key.drop(p.length + 1))
        }
        return words(key)
    }

    fun claudeWindow(key: String) = claudeBases.firstOrNull { key == it.first || key.startsWith(it.first + "_") }?.third

    fun parseISO(s: String): Instant? = runCatching { java.time.OffsetDateTime.parse(s).toInstant() }.getOrNull()
}

private fun JSONObject.str(k: String) = if (isNull(k)) null else opt(k) as? String
private fun JSONObject.num(k: String) = if (isNull(k)) null else (opt(k) as? Number)?.toDouble()

/** JSON for local storage. Only percentages, dates and names; never cookies or tokens. */
object Json {
    fun usage(list: List<ServiceUsage>) = JSONArray(list.map { u ->
        JSONObject().put("service", u.service).put("updated", u.updated.toEpochMilli()).put("error", u.error)
            .put("identity", u.identity).put("name", u.name).put("plan", u.plan).put("temporary", u.temporary)
            .put("accountId", u.accountId)
            .put("limits", JSONArray(u.limits.map { l ->
                JSONObject().put("name", l.name).put("percent", l.percent).put("resetsAt", l.resetsAt?.toEpochMilli()).put("window", l.window)
            }))
    }).toString()

    fun usage(s: String?): List<ServiceUsage> = runCatching {
        JSONArray(s ?: "[]").objects().map { o ->
            ServiceUsage(o.getString("service"), o.getJSONArray("limits").objects().map { l ->
                Limit(l.getString("name"), l.getDouble("percent"), l.millis("resetsAt"), l.num("window"))
            }, Instant.ofEpochMilli(o.getLong("updated")), o.str("error"), o.str("identity"), o.str("name"), o.str("plan"),
                o.optBoolean("temporary"), o.str("accountId"))
        }
    }.getOrDefault(emptyList())

    fun accounts(list: List<Account>) = JSONArray(list.map {
        JSONObject().put("id", it.id).put("service", it.service.name).put("label", it.label)
    }).toString()

    fun accounts(s: String?): List<Account> = runCatching {
        JSONArray(s ?: "[]").objects().map { Account(it.getString("id"), Service.valueOf(it.getString("service")), it.str("label")) }
    }.getOrDefault(emptyList())

    // Compact rows: [epochSeconds, account, limit, percent].
    fun samples(list: List<Sample>) = JSONArray(list.map { JSONArray().put(it.t.epochSecond).put(it.account).put(it.limit).put(it.p) }).toString()

    fun samples(s: String?): List<Sample> = runCatching {
        val a = JSONArray(s ?: "[]")
        (0 until a.length()).map { val r = a.getJSONArray(it); Sample(Instant.ofEpochSecond(r.getLong(0)), r.getString(1), r.getString(2), r.getDouble(3)) }
    }.getOrDefault(emptyList())

    fun dates(m: Map<String, Instant>) = JSONObject(m.mapValues { it.value.toEpochMilli() }).toString()
    fun dates(s: String?): Map<String, Instant> = runCatching {
        val o = JSONObject(s ?: "{}"); o.keys().asSequence().associateWith { Instant.ofEpochMilli(o.getLong(it)) }
    }.getOrDefault(emptyMap())

    fun states(m: Map<String, EarlyReset.State>) = JSONObject(m.mapValues {
        JSONObject().put("percent", it.value.percent).put("resetsAt", it.value.resetsAt?.toEpochMilli()).put("pendingLow", it.value.pendingLow)
    }).toString()

    fun states(s: String?): Map<String, EarlyReset.State> = runCatching {
        val o = JSONObject(s ?: "{}")
        o.keys().asSequence().associateWith { k -> o.getJSONObject(k).let { EarlyReset.State(it.getDouble("percent"), it.millis("resetsAt"), it.optBoolean("pendingLow")) } }
    }.getOrDefault(emptyMap())

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
    private fun JSONObject.millis(k: String) = if (isNull(k)) null else Instant.ofEpochMilli(getLong(k))
}
