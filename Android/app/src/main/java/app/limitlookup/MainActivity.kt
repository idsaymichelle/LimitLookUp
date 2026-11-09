package app.limitlookup

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Debug-only switches for screenshots with sample data.
        if (BuildConfig.DEBUG && intent.getBooleanExtra("demo", false)) AppModel.demo = true
        val tab = if (BuildConfig.DEBUG) intent.getIntExtra("tab", 0) else 0
        val ask = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        if (Build.VERSION.SDK_INT >= 33 && !AppModel.demo &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) ask.launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent { Root(tab) }
    }
}

@Composable
fun Root(startTab: Int) {
    val dark = when (Settings.theme) { "light" -> false; "dark" -> true; else -> isSystemInDarkTheme() }
    val view = LocalView.current
    SideEffect {
        val w = (view.context as Activity).window
        WindowCompat.getInsetsController(w, view).apply { isAppearanceLightStatusBars = !dark; isAppearanceLightNavigationBars = !dark }
    }
    LaunchedEffect(Unit) { AppModel.refresh() }
    var tab by rememberSaveable { mutableIntStateOf(startTab) }
    key(Settings.language) {
        LluTheme(dark) {
            Scaffold(containerColor = P.bg, bottomBar = {
                NavigationBar(containerColor = P.card) {
                    val colors = NavigationBarItemDefaults.colors(selectedIconColor = P.ink, selectedTextColor = P.ink,
                        indicatorColor = P.track, unselectedIconColor = P.sub, unselectedTextColor = P.sub)
                    NavigationBarItem(tab == 0, { tab = 0 }, { GaugeMark(22.dp, LocalContentColor.current) }, label = { Text(L("Limits")) }, colors = colors)
                    NavigationBarItem(tab == 1, { tab = 1 }, { BarsIcon(LocalContentColor.current) }, label = { Text(L("Stats")) }, colors = colors)
                    NavigationBarItem(tab == 2, { tab = 2 }, { Icon(Icons.Default.Settings, null) }, label = { Text(L("Settings")) }, colors = colors)
                }
            }) { pad ->
                Box(Modifier.padding(pad).fillMaxSize()) {
                    when (tab) { 0 -> LimitsScreen(); 1 -> StatsScreen(); else -> SettingsScreen() }
                }
            }
        }
    }
}

@Composable
fun BarsIcon(c: Color) = Canvas(Modifier.size(22.dp)) {
    val w = size.width / 5
    listOf(.45f, .8f, .6f).forEachIndexed { i, h ->
        drawRoundRect(c, Offset(w * (2 * i) + w / 2 - w / 2 + i * 0f, size.height * (1 - h)), Size(w, size.height * h), CornerRadius(w / 3))
    }
}

@Composable
fun PageTitle(text: String) = Text(text, style = font(32, FontWeight.Bold), color = P.ink, modifier = Modifier.padding(top = 4.dp))

@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(P.card).padding(18.dp), content = content)

private data class RowItem(val id: String, val service: Service, val label: String?, val usage: ServiceUsage?, val account: Account?)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LimitsScreen() {
    val scope = rememberCoroutineScope()
    var login by remember { mutableStateOf<Account?>(null) }
    var added by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<Account?>(null) }
    var removing by remember { mutableStateOf<Account?>(null) }
    val rows = if (AppModel.demo) AppModel.usage.map { u ->
        RowItem(u.service, Service.entries.firstOrNull { u.service.startsWith(it.title) } ?: Service.CLAUDE, null, u, null)
    } else AppModel.accounts.map { a ->
        RowItem(a.id, a.service, a.label?.takeIf { it.toIntOrNull() == null }, AppModel.usage.firstOrNull { it.accountId == a.id }, a)
    }
    val add = { s: Service -> val a = AppModel.addAccount(s); added = a.id; login = a }

    PullToRefreshBox(AppModel.loading, { scope.launch { AppModel.refresh() } }, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 6.dp)) {
                GaugeMark(27.dp)
                Spacer(Modifier.width(10.dp))
                Text("LimitLookUp", style = font(32, FontWeight.Bold).copy(brush = Brand.wordmark), maxLines = 1, modifier = Modifier.weight(1f))
                if (rows.isNotEmpty()) RefreshButton { scope.launch { AppModel.refresh() } }
            }
            if (rows.isEmpty()) EmptyState(add)
            rows.forEach { r ->
                AccountBlock(r.service, r.label, r.usage, r.account,
                    onLogin = { login = r.account }, onRename = { renaming = r.account }, onRemove = { removing = r.account })
            }
            if (rows.isNotEmpty() && !AppModel.demo) AddButton(false, add)
        }
    }

    login?.let { a ->
        LoginDialog(a) {
            login = null
            val id = added; added = null
            scope.launch {
                AppModel.refreshAfterLogin()
                // An account added just now whose sign-in was not finished is dropped again.
                if (id == a.id) {
                    val u = AppModel.usage.firstOrNull { it.accountId == id }
                    if (u == null || (u.limits.isEmpty() && !u.temporary)) AppModel.logout(a)
                }
            }
        }
    }
    renaming?.let { a ->
        var text by remember { mutableStateOf(a.label ?: "") }
        AlertDialog(onDismissRequest = { renaming = null }, title = { Text(L("Account name")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(L("Only you see this name. It helps tell accounts of the same service apart."))
                    OutlinedTextField(text, { text = it }, placeholder = { Text(L("For example, Work")) }, singleLine = true)
                }
            },
            confirmButton = { TextButton({ scope.launch { AppModel.rename(a, text) }; renaming = null }) { Text(L("Save")) } },
            dismissButton = { TextButton({ renaming = null }) { Text(L("Cancel")) } })
    }
    removing?.let { a ->
        AlertDialog(onDismissRequest = { removing = null }, title = { Text(L("Remove “%s”?", a.title)) },
            text = { Text(L("The sign-in will be deleted from this device. The account itself stays with the service.")) },
            confirmButton = { TextButton({ removing = null; scope.launch { AppModel.logout(a) } }) { Text(L("Remove account"), color = P.over) } },
            dismissButton = { TextButton({ removing = null }) { Text(L("Keep")) } })
    }
}

@Composable
private fun RefreshButton(onClick: () -> Unit) {
    val spin = rememberInfiniteTransition(label = "spin").animateFloat(0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Restart), label = "r")
    IconButton(onClick, enabled = !AppModel.loading, modifier = Modifier.size(42.dp).clip(CircleShape).background(P.card)) {
        Icon(Icons.Default.Refresh, L("Refresh"), tint = P.ink, modifier = Modifier.rotate(if (AppModel.loading) spin.value else 0f))
    }
}

@Composable
private fun EmptyState(add: (Service) -> Unit) {
    Column(Modifier.padding(top = 24.dp).fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(P.card).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        GaugeMark(64.dp)
        Text(L("No accounts yet"), style = font(20, FontWeight.SemiBold), color = P.ink)
        Text(L("Add an account to see how much of your limits is left and when they reset."), style = font(15), color = P.sub, textAlign = TextAlign.Center)
        AddButton(true, add)
    }
}

/** The service choice lives inside the button's menu. */
@Composable
private fun AddButton(prominent: Boolean, add: (Service) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().heightIn(min = if (prominent) 54.dp else 48.dp).clip(RoundedCornerShape(16.dp))
            .background(if (prominent) Brand.accent else P.card).clickable { open = true },
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            val c = if (prominent) P.bg else P.ink
            Icon(Icons.Default.Add, null, tint = c)
            Spacer(Modifier.width(6.dp))
            Text(L("Add account"), style = font(17, FontWeight.SemiBold), color = c)
        }
        DropdownMenu(open, { open = false }) {
            Service.entries.forEach { s -> DropdownMenuItem({ Text(s.title) }, { open = false; add(s) }) }
        }
    }
}

@Composable
fun AccountBlock(service: Service, label: String?, usage: ServiceUsage?, account: Account?,
                 onLogin: () -> Unit, onRename: () -> Unit, onRemove: () -> Unit) {
    val name = label ?: usage?.name
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(P.card)) {
        Row(Modifier.fillMaxWidth().background(Brand.fill(service)).padding(start = 18.dp, end = 6.dp, top = 16.dp, bottom = 16.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(service.title, style = font(20, FontWeight.Bold), color = Color.White, maxLines = 1)
                    if (Settings.showIdentity && !name.isNullOrEmpty())
                        Text(name, style = font(16, FontWeight.Medium), color = Color.White.copy(.85f), maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    usage?.plan?.let {
                        Text(it, style = font(12, FontWeight.SemiBold), color = Color.White,
                            modifier = Modifier.clip(CircleShape).background(Color.White.copy(.22f)).padding(horizontal = 7.dp, vertical = 2.dp))
                    }
                }
                if (Settings.showIdentity && !usage?.identity.isNullOrEmpty())
                    Text(usage!!.identity!!, style = font(13), color = Color.White.copy(.8f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (account != null) Box {
                var open by remember { mutableStateOf(false) }
                IconButton({ open = true }, Modifier.size(36.dp)) { Icon(Icons.Default.MoreVert, L("Actions for %s", service.title), tint = Color.White) }
                DropdownMenu(open, { open = false }) {
                    DropdownMenuItem({ Text(L("Sign in again")) }, { open = false; onLogin() }, leadingIcon = { Icon(Icons.Default.AccountCircle, null) })
                    DropdownMenuItem({ Text(L("Rename")) }, { open = false; onRename() }, leadingIcon = { Icon(Icons.Default.Edit, null) })
                    DropdownMenuItem({ Text(L("Remove account"), color = P.over) }, { open = false; onRemove() }, leadingIcon = { Icon(Icons.Default.Delete, null, tint = P.over) })
                }
            }
        }
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(if (Settings.compact) 14.dp else 18.dp)) {
            if (usage != null && usage.error == null) {
                usage.limits.forEach { LimitRow(it) }
                Text(relative(usage.updated), style = font(12), color = P.sub, modifier = Modifier.align(Alignment.End))
            } else {
                Text(usage?.error ?: L("Sign in to see your limits."), style = font(15), color = P.sub)
                OutlinedButton(onLogin) { Text(L("Sign in"), style = font(15, FontWeight.Medium), color = P.ink) }
            }
        }
    }
}

fun relative(d: Instant): String {
    val min = Duration.between(d, Instant.now()).toMinutes()
    return runCatching {
        val f = android.icu.text.RelativeDateTimeFormatter.getInstance(Lang.locale)
        when {
            min < 1 -> f.format(android.icu.text.RelativeDateTimeFormatter.Direction.PLAIN, android.icu.text.RelativeDateTimeFormatter.AbsoluteUnit.NOW)
            min < 60 -> f.format(min.toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.MINUTES)
            min < 1440 -> f.format((min / 60).toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.HOURS)
            else -> f.format((min / 1440).toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.DAYS)
        }
    }.getOrDefault("")
}

@Composable
fun LimitRow(limit: Limit) {
    val shown = (if (Settings.showRemaining) maxOf(0.0, 100 - limit.percent) else limit.percent).toInt()
    if (Settings.compact) {
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(limit.title, style = font(17), color = P.ink, maxLines = 1, modifier = Modifier.weight(1f))
                limit.resetsAt?.let { r ->
                    val soon = Duration.between(Instant.now(), r).seconds < 86400
                    Text(if (soon) L("Resets at %s", Lang.time(r)) else L("Resets %s", Lang.weekdayTime(r)), style = font(15), color = P.sub, maxLines = 1)
                }
                Text("$shown%", style = font(17, FontWeight.SemiBold, true), color = P.ink)
            }
            PaceBar(limit, 6.dp)
        }
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(limit.title, style = font(17, FontWeight.Medium), color = P.ink)
                limit.ratePerHour()?.let {
                    Text(L("%s%%/h", Lang.decimal(it)), style = font(13, digits = true), color = if (limit.pace() == Pace.FAST) P.warn else P.sub)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("$shown%", style = font(26, FontWeight.SemiBold, true), color = P.ink)
                if (Settings.showRemaining) Text(L("left"), style = font(12), color = P.sub)
            }
        }
        PaceBar(limit)
        limit.resetText()?.let { Text(L("Resets %s", it), style = font(13), color = P.sub) }
    }
}

/** The open site's address above a sign-in page, with a warning when it is not the service's own site. */
@Composable
fun SiteBar(host: String, expected: String) {
    val own = host == expected || host.endsWith(".$expected") || host.endsWith(".openai.com") || host == "openai.com"
    Row(Modifier.fillMaxWidth().background(P.card).padding(vertical = 6.dp), horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically) {
        val c = if (own) P.ink else Color.Red
        Icon(if (own) Icons.Default.Lock else Icons.Default.Warning, null, tint = c, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(6.dp))
        Text(host.ifEmpty { " " }, style = font(13, FontWeight.SemiBold), color = c)
    }
}

/** Sign-in on the service's own page, in the account's own WebView profile. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun LoginDialog(a: Account, onDone: () -> Unit) {
    Dialog(onDone, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        var host by remember { mutableStateOf("") }
        Column(Modifier.fillMaxSize().background(P.bg).systemBarsPadding().imePadding()) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(a.title, style = font(17, FontWeight.SemiBold), color = P.ink, modifier = Modifier.weight(1f))
                TextButton(onDone) { Text(L("Done"), style = font(17, FontWeight.SemiBold), color = Brand.accent) }
            }
            SiteBar(host, a.service.host)
            Text(L("Sign in with email. Google doesn’t allow its sign-in inside apps."), style = font(13, FontWeight.Medium), color = P.ink,
                modifier = Modifier.fillMaxWidth().background(Brand.accent.copy(.18f)).padding(horizontal = 16.dp, vertical = 10.dp))
            AndroidView(factory = { ctx ->
                WebView(ctx).apply {
                    Profiles.attach(this, a)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    Profiles.cookies(a).setAcceptThirdPartyCookies(this, true)
                    webViewClient = object : WebViewClient() {
                        override fun doUpdateVisitedHistory(v: WebView, url: String?, isReload: Boolean) { host = Uri.parse(url ?: "").host ?: "" }
                    }
                    loadUrl(a.service.loginUrl)
                }
            }, onRelease = { Profiles.cookies(a).flush(); it.destroy() }, modifier = Modifier.weight(1f).fillMaxWidth())
        }
    }
}
