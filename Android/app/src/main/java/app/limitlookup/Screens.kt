package app.limitlookup

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.WeekFields

@Composable
fun StatsScreen() {
    val samples = AppModel.history
    val threshold = Settings.threshold.toDouble()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        PageTitle(L("Stats"))
        OverviewCard(samples, threshold)
        HistoryCard(samples, AppModel.usage.filter { it.error == null }, threshold)
        ActivityCard(samples)
    }
}

@Composable
private fun OverviewCard(samples: List<Sample>, threshold: Double) {
    val o = remember(samples, threshold) { History.overview(samples, threshold) }
    Card {
        Text(L("Overview"), style = font(17, FontWeight.SemiBold), color = P.ink)
        Spacer(Modifier.height(14.dp))
        val tiles = listOf(
            Triple("${o.weekPeak.toInt()}%", L("Peak this week"), if (o.weekPeak >= threshold) P.over else P.ok),
            Triple("${o.daysNearLimit}", L("Days near the limit"), if (o.daysNearLimit > 0) P.amber else P.ok),
            Triple("${o.activeDays}", L("Active days"), P.ok),
            Triple(o.busiestWeekday?.let(Lang::weekdayName) ?: "—", L("Busiest day"), P.warn),
        )
        tiles.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(bottom = 10.dp).height(IntrinsicSize.Min)) {
                pair.forEach { (v, label, tint) ->
                    Column(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(16.dp)).background(P.bg.copy(.6f)).padding(14.dp)) {
                        Text(v, style = font(if (v.length > 6) 20 else 28, FontWeight.Bold), color = tint, maxLines = 1)
                        Text(label, style = font(13), color = P.sub)
                    }
                }
            }
        }
        Text(L("Last 30 days, from readings taken on this device."), style = font(12), color = P.sub)
    }
}

@Composable
private fun HistoryCard(samples: List<Sample>, usage: List<ServiceUsage>, threshold: Double) {
    val options = usage.flatMap { u -> u.limits.map { Triple("${u.service}|${it.name}", u.service, it) } }
    var pick by remember { mutableStateOf<String?>(null) }
    var range by remember { mutableStateOf(History.Range.D7) }
    val sel = options.firstOrNull { it.first == pick } ?: options.firstOrNull { it.third.name == "Week" } ?: options.firstOrNull()
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(L("History"), style = font(17, FontWeight.SemiBold), color = P.ink, modifier = Modifier.weight(1f))
            if (sel != null) Box {
                var open by remember { mutableStateOf(false) }
                Row(Modifier.clickable { open = true }, verticalAlignment = Alignment.CenterVertically) {
                    Text(L("%s: %s", sel.second, sel.third.title), style = font(12, FontWeight.Medium), color = P.sub, maxLines = 1)
                    Icon(Icons.Default.ArrowDropDown, null, tint = P.sub)
                }
                DropdownMenu(open, { open = false }) {
                    options.forEach { o -> DropdownMenuItem({ Text(L("%s: %s", o.second, o.third.title)) }, { pick = o.first; open = false }) }
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        Row(Modifier.fillMaxWidth().clip(CircleShape).background(P.track).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            History.Range.entries.forEach { r ->
                Box(Modifier.weight(1f).height(30.dp).clip(CircleShape).background(if (r == range) P.bg else Color.Transparent).clickable { range = r },
                    contentAlignment = Alignment.Center) {
                    Text(L(r.label), style = font(13, if (r == range) FontWeight.SemiBold else FontWeight.Normal), color = if (r == range) P.ink else P.sub)
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        if (sel == null) { Text(L("History appears after the first refresh."), style = font(15), color = P.sub); return@Card }
        val bars = remember(samples, sel.first, range) { History.bars(samples, sel.second, sel.third.name, range) }
        BarChart(bars, range, threshold)
        Spacer(Modifier.height(16.dp))
        val peak = bars.maxOf { it.peak }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(P.track.copy(.6f)).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("${Lang.dayMonth(bars.first().start)} – ${Lang.dayMonth(bars.last().start)}", style = font(12), color = P.sub)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(Brand.accent))
                Spacer(Modifier.width(6.dp))
                Text(if (peak > 0) L("Peak for the period: %d%%", peak.toInt()) else L("No data for this period yet"),
                    style = font(15, FontWeight.Medium), color = P.ink)
            }
        }
    }
}

@Composable
private fun BarChart(bars: List<History.Bar>, range: History.Range, threshold: Double) {
    val measurer = rememberTextMeasurer()
    val sub = P.sub; val line = P.line; val warn = P.warn
    val label = font(11).copy(color = sub)
    val fmt = when (range) {
        History.Range.H12, History.Range.H24 -> DateTimeFormatter.ofPattern("H", Lang.locale)
        History.Range.D3, History.Range.D7 -> DateTimeFormatter.ofPattern("EEE", Lang.locale)
        else -> DateTimeFormatter.ofPattern("d.M", Lang.locale)
    }
    Canvas(Modifier.fillMaxWidth().height(170.dp)) {
        val left = 34.dp.toPx(); val bottom = 18.dp.toPx()
        val h = size.height - bottom; val w = size.width - left
        for (v in listOf(0, 25, 50, 75, 100)) {
            val y = h * (1 - v / 100f)
            drawLine(line, Offset(left, y), Offset(size.width, y), 1f)
            drawText(measurer, "$v%", Offset(0f, (y - 7.dp.toPx()).coerceAtLeast(0f)), label)
        }
        val slot = w / bars.size
        val step = maxOf(1, bars.size / 6)
        bars.forEachIndexed { i, b ->
            val bh = h * (b.peak / 100).toFloat()
            drawRoundRect(if (i == bars.lastIndex) Brand.accent else Brand.accent.copy(.45f),
                Offset(left + slot * i + slot * .19f, h - bh), Size(slot * .62f, bh), CornerRadius(4.dp.toPx()))
            if ((bars.lastIndex - i) % step == 0)
                drawText(measurer, fmt.format(b.start.atZone(ZoneId.systemDefault())), Offset(left + slot * i, h + 3.dp.toPx()), label)
        }
        val ty = h * (1 - threshold / 100).toFloat()
        drawLine(warn.copy(.7f), Offset(left, ty), Offset(size.width, ty), 2f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
    }
}

/** Days as squares, darker = closer to the 5-hour limit that day. Columns are weeks (~90 days). */
@Composable
private fun ActivityCard(samples: List<Sample>) {
    val weeks = 13
    val today = LocalDate.now()
    val first = WeekFields.of(Lang.locale).firstDayOfWeek
    val start = today.with(java.time.temporal.TemporalAdjusters.previousOrSame(first)).minusWeeks(weeks - 1L)
    val values = remember(samples) { History.activity(samples, (today.toEpochDay() - start.toEpochDay() + 1).toInt()) }
    val track = P.track
    fun color(v: Double?) = if (v == null || v <= 0) track else Brand.accent.copy(if (v < 25) .3f else if (v < 50) .5f else if (v < 75) .75f else 1f)
    Card {
        Text(L("Activity"), style = font(17, FontWeight.SemiBold), color = P.ink)
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (w in 0 until weeks) {
                val ws = start.plusWeeks(w.toLong())
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val label = if (ws.minusWeeks(1).month != ws.month) Lang.month(ws.atStartOfDay(ZoneId.systemDefault()).toInstant()) else ""
                    Text(label, style = font(11), color = P.sub, maxLines = 1, softWrap = false, modifier = Modifier.height(14.dp).wrapContentWidth(Alignment.Start, unbounded = true))
                    for (d in 0 until 7) {
                        val day = ws.plusDays(d.toLong())
                        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(3.dp))
                            .background(if (day > today) Color.Transparent else color(values[day])))
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(L("Less"), style = font(11), color = P.sub)
            listOf(0.0, 20.0, 45.0, 70.0, 95.0).forEach { Box(Modifier.size(11.dp).clip(RoundedCornerShape(3.dp)).background(color(it))) }
            Text(L("More"), style = font(11), color = P.sub)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen() {
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current
    var confirmClear by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val switchColors = SwitchDefaults.colors(checkedTrackColor = Brand.accent)

    @Composable fun Header(t: String) = Text(t, style = font(13, FontWeight.SemiBold), color = P.sub, modifier = Modifier.padding(start = 4.dp, top = 8.dp))
    @Composable fun Toggle(t: String, v: Boolean, set: (Boolean) -> Unit) =
        Row(Modifier.fillMaxWidth().clickable { set(!v) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(t, style = font(16), color = P.ink, modifier = Modifier.weight(1f)); Switch(v, set, colors = switchColors)
        }
    @Composable fun Segments(options: List<Pair<String, String>>, value: String, set: (String) -> Unit) =
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            options.forEachIndexed { i, (k, t) ->
                SegmentedButton(value == k, { set(k) }, SegmentedButtonDefaults.itemShape(i, options.size),
                    colors = SegmentedButtonDefaults.colors(activeContainerColor = P.bg, activeContentColor = P.ink, inactiveContainerColor = P.card)) {
                    Text(t, style = font(14), maxLines = 1)
                }
            }
        }
    @Composable fun Action(t: String, color: Color = P.ink, onClick: () -> Unit) =
        Text(t, style = font(16), color = color, modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp))

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        PageTitle(L("Settings"))

        Header(L("Appearance"))
        Card {
            Text(L("Theme"), style = font(13), color = P.sub)
            Segments(listOf("system" to L("System"), "light" to L("Light"), "dark" to L("Dark")), Settings.theme) { Settings.theme = it }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("Language"), style = font(16), color = P.ink, modifier = Modifier.weight(1f))
                Box {
                    var open by remember { mutableStateOf(false) }
                    TextButton({ open = true }) {
                        Text(appLanguages.firstOrNull { it.first == Settings.language }?.second ?: L("System"), style = font(16), color = Brand.accent)
                    }
                    DropdownMenu(open, { open = false }) {
                        (listOf("" to L("System")) + appLanguages).forEach { (code, name) ->
                            DropdownMenuItem({ Text(name) }, {
                                open = false; Lang.set(code); Settings.language = code
                                scope.launch { AppModel.refresh(); AppModel.widgets() } // re-create messages stored in the old language
                            })
                        }
                    }
                }
            }
            Text(L("Layout"), style = font(13), color = P.sub)
            Segments(listOf("d" to L("Detailed"), "c" to L("Compact")), if (Settings.compact) "c" else "d") { Settings.compact = it == "c" }
            if (Settings.compact) Column(Modifier.padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                val now = java.time.Instant.now()
                LimitRow(Limit("5 hours", 97.0, now.plusSeconds(7200), 18000.0))
                LimitRow(Limit("Week", 53.0, now.plusSeconds(4 * 86400), 604800.0))
            }
            Toggle(L("Show remaining"), Settings.showRemaining) { Settings.showRemaining = it; scope.launch { AppModel.widgets() } }
            Toggle(L("Show account name and email"), Settings.showIdentity) { Settings.showIdentity = it }
        }

        Header(L("Notifications"))
        Card {
            Toggle(L("Limit almost used up"), Settings.notifyThreshold) { Settings.notifyThreshold = it }
            if (Settings.notifyThreshold) {
                Text(L("Notify at %d%% used", Settings.threshold.toInt()), style = font(16), color = P.ink)
                Slider(Settings.threshold, { Settings.threshold = it }, valueRange = 50f..100f, steps = 9,
                    colors = SliderDefaults.colors(thumbColor = Brand.accent, activeTrackColor = Brand.accent))
            }
            Toggle(L("Limit reset"), Settings.notifyReset) { Settings.notifyReset = it }
            Toggle(L("Limit reset early"), Settings.notifyEarly) { Settings.notifyEarly = it }
        }
        Text(L("An early reset is when a service restores a limit before the announced time."), style = font(12), color = P.sub, modifier = Modifier.padding(horizontal = 4.dp))

        Header(L("Data"))
        Card {
            Action(L("Clear history"), P.over) { confirmClear = true }
            Action(L("Delete all data"), P.over) { confirmDelete = true }
        }

        Header(L("About"))
        Card {
            Text(L("LimitLookUp has no server of its own. Limits are requested only from the sites of the services you add and are stored on this device."),
                style = font(13), color = P.sub)
            Spacer(Modifier.height(6.dp))
            Action(L("Privacy Policy"), Brand.accent) { uri.openUri("https://github.com/idsaymichelle/LimitLookUp#privacy") }
            Action(L("Terms of Use"), Brand.accent) { uri.openUri("https://github.com/idsaymichelle/LimitLookUp/blob/main/LICENSE") }
            Action(L("Help and support"), Brand.accent) { uri.openUri("https://github.com/idsaymichelle/LimitLookUp/issues") }
            Row(Modifier.padding(vertical = 10.dp)) {
                Text(L("Version"), style = font(16), color = P.ink, modifier = Modifier.weight(1f))
                Text(BuildConfig.VERSION_NAME, style = font(16), color = P.sub)
            }
        }
    }

    if (confirmClear) AlertDialog({ confirmClear = false }, title = { Text(L("Clear history?")) },
        text = { Text(L("Charts and activity will start from scratch. Limits and accounts are not affected.")) },
        confirmButton = { TextButton({ confirmClear = false; AppModel.clearHistory() }) { Text(L("Clear history"), color = P.over) } },
        dismissButton = { TextButton({ confirmClear = false }) { Text(L("Cancel")) } })
    // shortcut: Android-only wording (no profile or iCloud here), English until translated in Localizable.xcstrings.
    if (confirmDelete) AlertDialog({ confirmDelete = false }, title = { Text(L("Delete all data?")) },
        text = { Text(L("All accounts and their sign-ins, history and settings will be removed from this device. This can't be undone.")) },
        confirmButton = { TextButton({ confirmDelete = false; scope.launch { AppModel.deleteAll() } }) { Text(L("Delete all data"), color = P.over) } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text(L("Cancel")) } })
}
