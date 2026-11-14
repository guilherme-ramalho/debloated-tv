package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.net.URI
import java.net.URLEncoder

/** "192.168.1.20", "192.168.1.20:15555" or "mac.local:15555" (an emulator shared from a Mac). Port 5555 by default. */
data class TVAddress(val host: String, val port: Int) {
    companion object {
        fun parse(text: String): TVAddress? {
            val parts = text.trim().split(":")
            val first = parts.first()
            if (first.isEmpty() || parts.size > 2 || first.any { it.isWhitespace() }) return null
            val port = if (parts.size == 2) parts[1].toIntOrNull()?.takeIf { it in 1..65535 } ?: return null else 5555
            return TVAddress(first, port)
        }

        /** Four numbers 0–255 separated by dots. */
        fun isIPv4(text: String): Boolean {
            val parts = text.split(".")
            return parts.size == 4 && parts.all { part ->
                part.isNotEmpty() && part.length <= 3 && part.all { it.code < 128 } && (part.toIntOrNull()?.let { it in 0..255 } == true)
            }
        }

        /** What a person typed into an address field, tidied: keyboards in many regions type a comma for the dot. */
        fun typed(text: String): String = text.replace(",", ".").filter { !it.isWhitespace() }
    }
}

/**
 * What the app knows about each TV's setup, keyed by the TV's address: whether our Home screen is on it, whether its
 * model has a list, and what the last setup did. Same JSON keys as the iPhone's TVSetupInfo.
 */
@Serializable
data class TVSetupInfo(
    val homeInstalled: Boolean = false,
    /** null until a setup connection has read the TV's model. */
    val supported: Boolean? = null,
    /** "Brand Model"; empty when the TV didn't say (the app shows "Unknown model"). */
    val model: String = "",
    /** "device · Android 11". */
    val detail: String = "",
    val profile: String = "",
    val disabledCount: Int? = null,
    /** The one-time "set up your TV" sheet after pairing was shown. */
    val offered: Boolean = false,
    /** Paired, offer not decided yet: waiting to see which Home the TV has (it was showing an app). */
    val offerPending: Boolean? = null,
)

/** Where [TVSetupStatus] keeps its JSON (SharedPreferences in the app; a field in tests). */
interface SetupStatusStore {
    fun load(): String?
    fun save(json: String)
}

/**
 * The TV tab's knowledge per TV (TVSetupStatus in Swift). [backup]: an optional second store that survives
 * reinstalling the app (the iPhone uses the Keychain); read when [store] is empty and kept in step with it.
 * Use from the main thread; [scope] runs the delayed offer.
 */
class TVSetupStatus(
    private val store: SetupStatusStore,
    private val scope: CoroutineScope,
    private val offerDelayMs: Long = 1500,
    private val backup: SetupStatusStore? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private val serializer = MapSerializer(String.serializer(), TVSetupInfo.serializer())
    private val _all = MutableStateFlow<Map<String, TVSetupInfo>>(emptyMap())
    val all: StateFlow<Map<String, TVSetupInfo>> = _all.asStateFlow()
    /** The TV the one-time offer is showing for. */
    val offerFor = MutableStateFlow<String?>(null)
    /** Set to open the setup flow from the TV tab. */
    val openSetup = MutableStateFlow(false)

    init {
        val local = store.load()
        val saved = local ?: backup?.load()
        _all.value = saved?.let { try { json.decodeFromString(serializer, it) } catch (e: Exception) { null } } ?: emptyMap()
        // State saved before the backup existed only reaches it on its next change, which may never come.
        if (backup != null && local != null && backup.load() != local) backup.save(local)
    }

    fun info(host: String): TVSetupInfo = _all.value[host] ?: TVSetupInfo()

    fun update(host: String, change: (TVSetupInfo) -> TVSetupInfo) {
        if (host.isEmpty()) return
        val value = change(info(host))
        if (value == _all.value[host]) return
        _all.value = _all.value + (host to value)
        val data = json.encodeToString(serializer, _all.value)
        store.save(data)
        backup?.save(data)
    }

    /** The TV showed our Home screen, or its editor answered. */
    fun sawHome(host: String) = update(host) { it.copy(homeInstalled = true) }

    /** Undo put the stock launcher back. */
    fun restored(host: String) = update(host) { it.copy(homeInstalled = false, disabledCount = null) }

    /**
     * Right after a new pairing: offer setup once, but only on a TV seen showing a stock Home screen. A TV showing our
     * Home is set up already (no offer); a TV showing an app keeps the offer pending until it shows a Home. Nothing is
     * pressed on the TV to find out, so what's playing is never interrupted.
     */
    fun offerAfterPairing(host: String, showing: String) {
        val current = info(host)
        if (host.isEmpty() || current.offered || current.homeInstalled) return
        update(host) { it.copy(offerPending = true) }
        sawForeground(host, showing)
    }

    /** What the TV reports in front. Ours means set up; a stock launcher settles a pending offer. */
    fun sawForeground(host: String, pkg: String) {
        if (pkg == HOME_PACKAGE) {
            update(host) { it.copy(homeInstalled = true, offerPending = null) }
            return
        }
        // Setup disables the stock launcher, so seeing one means the TV was put back outside this app (a restore from
        // a computer, a factory reset): the TV tab offers setup again instead of an editor with nothing behind it.
        if (pkg in DebloatRules.stockLaunchers && info(host).homeInstalled) update(host) { it.copy(homeInstalled = false, disabledCount = null) }
        if (info(host).offerPending != true || info(host).homeInstalled || !isLauncher(pkg)) return
        update(host) { it.copy(offerPending = null, offered = true) }
        scope.launch {
            delay(offerDelayMs)   // let the pairing sheet close first
            if (!info(host).homeInstalled) offerFor.value = host
        }
    }

    /** Records what a setup connection learned about the TV. [listsFound]: lists fit but none is chosen yet. */
    fun inspected(host: String, properties: Map<String, String>, profile: DebloatProfile?, listsFound: Boolean = false) =
        update(host) { info ->
            val brand = (properties["ro.product.manufacturer"] ?: "").trim()
            val model = (properties["ro.product.model"] ?: "").trim()
            info.copy(
                supported = profile != null || listsFound,
                profile = profile?.manifest?.name ?: "",
                model = if (model.isEmpty()) "" else if (brand.isEmpty() || model.contains(brand, ignoreCase = true)) model else "$brand $model",
                detail = listOf(properties["ro.product.device"], properties["ro.build.version.release"]?.let { "Android $it" })
                    .mapNotNull { it?.trim() }.filter { it.isNotEmpty() }.joinToString(" · "),
            )
        }

    companion object {
        const val HOME_PACKAGE = "com.gathin.tvhome"

        /** A Home screen app: the known stock launchers, or a package named like one. */
        fun isLauncher(pkg: String): Boolean = pkg in DebloatRules.stockLaunchers ||
            Regex("(launcher|tvhome|homescreen|\\.home$)", RegexOption.IGNORE_CASE).containsMatchIn(pkg)
    }
}

/** Asking for a TV model to be supported, without an account or a server of our own. */
object ModelRequest {
    /** A prefilled web form that takes the details without sign-in. null: share the details instead. */
    val formURL: String? = null
    const val ADD_TV_GUIDE = "https://github.com/guilherme-ramalho/debloated-tv/tree/main/ios/Resources/Profiles"

    /** English text (the app may build its own translated one from the same fields). */
    fun text(info: TVSetupInfo): String =
        "Purio TV: please add support for this TV.\nModel: ${info.model.ifEmpty { "Unknown model" }}\nDetails: ${info.detail}"

    /** The form with model and details added; only https. */
    fun url(info: TVSetupInfo, form: String? = formURL): String? {
        val base = form ?: return null
        val uri = try { URI(base) } catch (e: Exception) { return null }
        if (uri.scheme != "https") return null
        fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8).replace("+", "%20")
        val extra = "model=${enc(info.model)}&details=${enc(info.detail)}"
        val query = uri.rawQuery?.let { "$it&$extra" } ?: extra
        val fragment = uri.rawFragment?.let { "#$it" } ?: ""
        return base.substringBefore('#').substringBefore('?') + "?" + query + fragment
    }
}
