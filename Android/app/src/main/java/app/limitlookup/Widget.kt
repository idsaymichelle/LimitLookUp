package app.limitlookup

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle

class LimitsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = LimitsWidget()
}

/** The accounts closest to their limits, from the numbers the app saved last. */
class LimitsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        Store.init(context)
        if (Lang.loader == null) Lang.loader = { c -> runCatching { context.assets.open("strings/$c.json").bufferedReader().readText() }.getOrNull() }
        Lang.set(Settings.language)
        val usage = Store.usage().filter { it.error == null && it.limits.isNotEmpty() }
            .sortedByDescending { u -> u.limits.maxOf { it.percent } }.take(2)
        val remaining = Settings.showRemaining
        provideContent { Content(usage, remaining) }
    }

    @Composable
    private fun Content(usage: List<ServiceUsage>, remaining: Boolean) {
        fun c(light: Long, dark: Long) = ColorProvider(Color(light), Color(dark))
        val ink = c(0xFF1E1D1B, 0xFFE8E6DE); val sub = c(0xFF6B6962, 0xFF8F8C83)
        Column(GlanceModifier.fillMaxSize().background(c(0xFFEDEBE4, 0xFF1E1C1A)).cornerRadius(22.dp).padding(14.dp)
            .clickable(actionStartActivity<MainActivity>())) {
            if (usage.isEmpty()) {
                Text(L("Open LimitLookUp and sign in to an account"), style = TextStyle(color = sub, fontSize = 13.sp))
                return@Column
            }
            for (u in usage) {
                Text(u.service, style = TextStyle(color = if (u.service.startsWith("Codex")) c(0xFF4E6FBF, 0xFF7096D8) else c(0xFFC26D4A, 0xFFD98A63),
                    fontWeight = FontWeight.Bold, fontSize = 13.sp))
                for (l in u.limits.take(2)) {
                    Row(GlanceModifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(l.title, style = TextStyle(color = ink, fontSize = 12.sp), modifier = GlanceModifier.defaultWeight())
                        Text("${(if (remaining) maxOf(0.0, 100 - l.percent) else l.percent).toInt()}%",
                            style = TextStyle(color = ink, fontWeight = FontWeight.Bold, fontSize = 13.sp))
                    }
                    val col = if (l.percent >= 90) c(0xFF9A463D, 0xFFC46F64) else if (l.percent >= 70) c(0xFF9C7A2A, 0xFFCDAE62) else c(0xFF4A7656, 0xFF7FA588)
                    LinearProgressIndicator((l.percent / 100).toFloat(), GlanceModifier.fillMaxWidth().height(5.dp).cornerRadius(3.dp),
                        color = col, backgroundColor = c(0xFFD6D3C9, 0xFF3A3734))
                }
                Spacer(GlanceModifier.height(8.dp))
            }
        }
    }
}
