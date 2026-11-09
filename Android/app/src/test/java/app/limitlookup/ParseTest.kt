package app.limitlookup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

/** Port of Tests/ParseCheck.swift (Claude and Codex parts; Kimi, Qwen and iCloud sync are not in the Android app). */
class ParseTest {
    @Test fun claude() {
        val c = Parse.parse(Service.CLAUDE, """{"five_hour":{"utilization":42,"resets_at":"2026-11-08T05:00:00.123+00:00"},"seven_day":{"utilization":7.5,"resets_at":null},"seven_day_opus":null,"extra":5}""")
        assertNull(c.error)
        assertEquals(listOf("5 hours", "Week"), c.limits.map { it.name })
        assertEquals(42.0, c.limits[0].percent, 0.0)
        assertNotNull(c.limits[0].resetsAt); assertNull(c.limits[1].resetsAt)
        assertEquals(18000.0, c.limits[0].window); assertEquals(604800.0, c.limits[1].window)
    }

    @Test fun codex() {
        val x = Parse.parse(Service.CODEX, """{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":4,"reset_at":1762578000,"limit_window_seconds":18000},"secondary_window":{"used_percent":61,"reset_at":1763000000,"limit_window_seconds":604800}}}""")
        assertEquals(listOf("5 hours", "Week"), x.limits.map { it.name })
        assertEquals(61.0, x.limits[1].percent, 0.0)
        assertEquals(18000.0, x.limits[0].window)
        assertEquals(Instant.ofEpochSecond(1762578000), x.limits[0].resetsAt)
        val y = Parse.parse(Service.CODEX, """{"rate_limit":{"primary_window":{"used_percent":9,"reset_after_seconds":600,"limit_window_seconds":18000}}}""")
        assertNotNull("reset_after_seconds fallback", y.limits.first().resetsAt)
    }

    @Test fun errors() {
        assertTrue(Parse.parse(Service.CLAUDE, """{"error":"blocked"}""").error!!.startsWith("The site wants"))
        assertEquals("Sign in to see your limits.", Parse.parse(Service.CODEX, """{"error":"auth"}""").error)
        assertEquals("The site returned an error (HTTP 500). Pull down to try again.", Parse.parse(Service.CODEX, """{"error":"HTTP 500"}""").error)
        assertTrue(Parse.parse(Service.CODEX, "{}").error!!.startsWith("The site sent no"))
        assertTrue(runCatching { Parse.parse(Service.CODEX, "<html>") }.isFailure)
    }

    @Test fun fableAndPlan() {
        val fb = Parse.parse(Service.CLAUDE, """{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"seven_day_fable":{"utilization":34,"resets_at":null},"_plan":"default_claude_max_5x","_identity":"a@x.com","_name":"A"}""")
        assertTrue(fb.limits.map { it.name }.contains("Week, Fable")); assertEquals("Max 5x", fb.plan)
        assertEquals("a@x.com", fb.identity); assertEquals("A", fb.name)
        val nw = Parse.parse(Service.CLAUDE, """{"five_hour":{"utilization":1,"resets_at":null},"seven_day_opus_4":{"utilization":2,"resets_at":null},"five_hour_fable":{"utilization":3,"resets_at":null}}""")
        assertEquals(listOf("5 hours", "5 hours, Fable", "Week, Opus 4"), nw.limits.map { it.name })
        assertEquals(listOf(18000.0, 18000.0, 604800.0), nw.limits.map { it.window })
        val ns = Parse.parse(Service.CLAUDE, """{"five_hour":{"utilization":5,"resets_at":null},"seven_day":{"utilization":82,"resets_at":null},"seven_day_opus":null,"limits":[{"kind":"session","group":"session","percent":5,"resets_at":"2026-11-10T01:29:59.552459+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":82,"resets_at":"2026-11-11T20:59:59.552480+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-11-11T20:59:59.552794+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],"seven_day_breakdown":{"rows":[{"key":"chat","percent":0}]}}""")
        assertEquals(listOf("5 hours", "Week", "Week, Fable"), ns.limits.map { it.name })
        assertEquals(listOf(18000.0, 604800.0, 604800.0), ns.limits.map { it.window })
        val pr = Parse.parse(Service.CLAUDE, """{"five_hour":{"utilization":10,"resets_at":null},"seven_day_fable":null,"_plan":"claude_pro"}""")
        assertTrue("Week, Fable" !in pr.limits.map { it.name }); assertEquals("Pro", pr.plan)
    }

    @Test fun paceAndRate() {
        val now = Instant.ofEpochSecond(2_000_000); val half = now.plusSeconds(9000)
        assertEquals(Pace.FAST, Limit("a", 80.0, half, 18000.0).pace(now))
        assertEquals(Pace.EVEN, Limit("a", 50.0, half, 18000.0).pace(now))
        assertEquals(Pace.SPARE, Limit("a", 20.0, half, 18000.0).pace(now))
        assertNull("no window, no pace", Limit("a", 80.0, half).pace(now))
        assertEquals(20.0, Limit("a", 50.0, half, 18000.0).ratePerHour(now)!!, 0.01)
        val rt = Limit("a", 1.0, half, 18000.0).resetText(now)!!
        assertTrue(rt, rt.startsWith("in 2") && rt.contains("("))
    }

    @Test fun history() {
        val zone = ZoneOffset.UTC
        val t0 = Instant.ofEpochSecond(1_800_000_000)
        val use = listOf(ServiceUsage("A", listOf(Limit("5 hours", 10.0, null)), t0, null))
        var hist = History.record(use, listOf(Sample(t0.minusSeconds(100 * 86400), "A", "5 hours", 1.0)), t0)
        assertEquals("old sample pruned, new one added", 1, hist.size)
        hist = History.record(use, hist, t0.plusSeconds(60))
        assertEquals("same value within 20 min is skipped", 1, hist.size)
        hist = hist + Sample(t0.minusSeconds(86400), "A", "5 hours", 70.0)
        val bars = History.bars(hist, "A", "5 hours", History.Range.D7, t0, zone)
        assertEquals(7, bars.size); assertEquals(10.0, bars.last().peak, 0.0); assertEquals(70.0, bars[5].peak, 0.0)
        assertEquals(2, History.activity(hist, 7, t0, zone).size)
        val ov = History.overview(hist, 50.0, t0, zone)
        assertEquals(70.0, ov.weekPeak, 0.0); assertEquals(1, ov.daysNearLimit); assertEquals(2, ov.activeDays); assertNotNull(ov.busiestWeekday)
    }

    @Test fun alertLog() {
        val r1 = Instant.ofEpochSecond(1_900_000_000)
        assertEquals(AlertLog.key("Codex", "5 hours", r1), AlertLog.key("Codex", "5 hours", r1.plusSeconds(40)))
        assertTrue(AlertLog.key("Codex", "5 hours", r1) != AlertLog.key("Codex", "5 hours", r1.plusSeconds(18000)))
        assertEquals(listOf("new"), AlertLog.pruned(mapOf("old" to r1, "new" to r1.plusSeconds(3 * 86400)), r1.plusSeconds(2 * 86400)).keys.sorted())
    }

    @Test fun earlyReset() {
        val t0 = Instant.ofEpochSecond(1_000_000); val sched = t0.plusSeconds(3 * 3600)
        val high = EarlyReset.State(70.0, sched)
        val low = Limit("5 hours", 0.0, null)
        val s1 = EarlyReset.check(high, low, t0)
        assertTrue("first low sample only arms", !s1.first && s1.second.pendingLow)
        assertTrue("second low confirms", EarlyReset.check(s1.second, low, t0.plusSeconds(600)).first)
        assertTrue("moved reset time confirms at once", EarlyReset.check(high, Limit("5 hours", 1.0, sched.plusSeconds(5 * 3600)), t0).first)
        assertTrue("on-time reset is not early", !EarlyReset.check(high, low, sched.plusSeconds(10)).first)
        val blip = EarlyReset.check(s1.second, Limit("5 hours", 71.0, sched), t0)
        assertTrue("glitch then normal clears pending", !blip.first && !blip.second.pendingLow)
    }

    @Test fun storageRoundTrip() {
        val u = listOf(ServiceUsage("Codex", listOf(Limit("Week", 12.5, Instant.ofEpochSecond(5), 604800.0)), Instant.ofEpochSecond(9), null, "a@x.com", accountId = "id"))
        assertEquals(u, Json.usage(Json.usage(u)))
        val a = listOf(Account(service = Service.CLAUDE, label = "Work"))
        assertEquals(a, Json.accounts(Json.accounts(a)))
        val s = listOf(Sample(Instant.ofEpochSecond(7), "A", "Week", 3.0))
        assertEquals(s, Json.samples(Json.samples(s)))
    }
}
