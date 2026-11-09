package app.limitlookup

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Warm, quiet palette from Shared/Theme.swift: cream paper / soft graphite, muted sage / ochre / rose for state. */
data class Palette(
    val bg: Color, val ink: Color, val sub: Color, val line: Color, val card: Color, val track: Color,
    val ok: Color, val warn: Color, val amber: Color, val over: Color,
)

val LightPalette = Palette(Color(0xFFEDEBE4), Color(0xFF1E1D1B), Color(0xFF6B6962), Color(0xFFD9D6CC), Color(0xFFE3E0D7),
    Color(0xFFD6D3C9), Color(0xFF4A7656), Color(0xFF9C7A2A), Color(0xFFA8613A), Color(0xFF9A463D))
val DarkPalette = Palette(Color(0xFF1E1C1A), Color(0xFFE8E6DE), Color(0xFF8F8C83), Color(0xFF35322F), Color(0xFF2A2826),
    Color(0xFF3A3734), Color(0xFF7FA588), Color(0xFFCDAE62), Color(0xFFCF8C5E), Color(0xFFC46F64))

val LocalPalette = staticCompositionLocalOf { LightPalette }
val P: Palette @Composable get() = LocalPalette.current

object Brand {
    val accent = Color(0xFFE6733C)
    val accentDeep = Color(0xFFC65A28)
    val claude = listOf(Color(0xFFD98A63), Color(0xFFC26D4A))
    val codex = listOf(Color(0xFF7096D8), Color(0xFF4E6FBF))
    /** App icon arcs, outer to inner. */
    val arcs = listOf(Color(0xFFDB331A), Color(0xFFCC480B), Color(0xFFFD8B49))
    fun fill(s: Service) = Brush.linearGradient(if (s == Service.CLAUDE) claude else codex)
    val wordmark = Brush.horizontalGradient(listOf(accent, accentDeep))
}

/** Figtree, as on the website: close to Avenir Next, with tabular digits. Other scripts fall back to the system font. */
val Figtree = FontFamily(
    Font(R.font.figtree_regular, FontWeight.Normal), Font(R.font.figtree_medium, FontWeight.Medium),
    Font(R.font.figtree_semibold, FontWeight.SemiBold), Font(R.font.figtree_bold, FontWeight.Bold),
)

fun font(size: Int, weight: FontWeight = FontWeight.Normal, digits: Boolean = false) =
    TextStyle(fontFamily = Figtree, fontSize = size.sp, fontWeight = weight, fontFeatureSettings = if (digits) "tnum" else null)

@Composable
fun LluTheme(dark: Boolean, content: @Composable () -> Unit) {
    val p = if (dark) DarkPalette else LightPalette
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = Brand.accent, onPrimary = Color.White, background = p.bg, onBackground = p.ink,
        surface = p.bg, onSurface = p.ink, onSurfaceVariant = p.sub, surfaceContainer = p.card, surfaceContainerHigh = p.card,
        surfaceContainerHighest = p.track, secondaryContainer = p.track, onSecondaryContainer = p.ink, outline = p.line,
        outlineVariant = p.line, error = p.over,
    )
    val t = Typography()
    val typo = Typography(
        bodyLarge = t.bodyLarge.copy(fontFamily = Figtree), bodyMedium = t.bodyMedium.copy(fontFamily = Figtree),
        bodySmall = t.bodySmall.copy(fontFamily = Figtree), labelLarge = t.labelLarge.copy(fontFamily = Figtree),
        labelMedium = t.labelMedium.copy(fontFamily = Figtree), labelSmall = t.labelSmall.copy(fontFamily = Figtree),
        titleLarge = t.titleLarge.copy(fontFamily = Figtree, fontWeight = FontWeight.SemiBold),
        titleMedium = t.titleMedium.copy(fontFamily = Figtree), headlineSmall = t.headlineSmall.copy(fontFamily = Figtree),
    )
    CompositionLocalProvider(LocalPalette provides p) { MaterialTheme(scheme, typography = typo, content = content) }
}

fun limitColor(percent: Double, p: Palette) = if (percent >= 90) p.over else if (percent >= 70) p.warn else p.ok

/** The app's mark: the icon's three arcs (scripts/make_icons.py), drawn to fill the box. */
@Composable
fun GaugeMark(size: Dp, tint: Color? = null) {
    Canvas(Modifier.size(size)) {
        val unit = this.size.minDimension / (2 * 386.56f)
        val c = center
        listOf(348.16f to .75f, 240.64f to .5f, 133.12f to .25f).forEachIndexed { i, (r0, len) ->
            val r = r0 * unit
            drawArc(tint ?: Brand.arcs[i], -90f, 360 * len, false, Offset(c.x - r, c.y - r), Size(2 * r, 2 * r),
                style = Stroke(76.8f * unit, cap = StrokeCap.Round))
        }
    }
}

/** Spent share on a track tinted with the same color, so the bar reads as one object. */
@Composable
fun PaceBar(limit: Limit, height: Dp = 8.dp) {
    val color = limitColor(limit.percent, P)
    val frac by animateFloatAsState((limit.percent / 100).toFloat().coerceIn(0f, 1f), label = "pace")
    Box(Modifier.fillMaxWidth().height(height).clip(CircleShape).background(color.copy(alpha = .18f))) {
        Box(Modifier.fillMaxWidth(frac).widthIn(min = height).fillMaxHeight().clip(CircleShape).background(color))
    }
}
