package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

/**
 * What kind of TV a device on the network is, told by the ports it answers on (port knocking, as couch-tv does),
 * and what Purio can do on it (TVKind.swift).
 */
enum class TvKind(val label: String) {
    ANDROID_TV("Android TV"), ROKU("Roku"), LG("LG webOS"), SAMSUNG("Samsung"), CHROMECAST("Chromecast")
}

/** What Purio can do on a TV of that kind today. */
sealed interface TvSupport {
    /** Android TV / Google TV: remote, TV setup, and Show on TV when Chromecast built-in answers. */
    data class Full(val showOnTv: Boolean) : TvSupport
    /** Roku, LG, Samsung: the remote and the TV's apps (TvBrands.kt); no TV setup, Home or Show on TV. */
    data object Remote : TvSupport
    /** A Chromecast with no remote service. */
    data object NotYet : TvSupport
    val canPair: Boolean get() = this != NotYet
}

object TvPorts {
    const val ANDROID_REMOTE = 6466
    const val CAST = 8009
    const val ROKU = 8060
    val LG = listOf(3000, 3001)
    val SAMSUNG = listOf(8001, 8002)
    /** Every port knocked on, each once per TV while the Connect screen is open. ADB (5555) is never knocked. */
    val ALL = listOf(ANDROID_REMOTE, CAST, ROKU) + LG + SAMSUNG

    /** The remote services win over Cast, which many TVs have too. */
    fun kind(open: Set<Int>): TvKind? = when {
        ANDROID_REMOTE in open -> TvKind.ANDROID_TV
        ROKU in open -> TvKind.ROKU
        LG.any { it in open } -> TvKind.LG
        SAMSUNG.any { it in open } -> TvKind.SAMSUNG
        CAST in open -> TvKind.CHROMECAST
        else -> null
    }

    fun support(kind: TvKind, open: Set<Int>): TvSupport = when (kind) {
        TvKind.ANDROID_TV -> TvSupport.Full(CAST in open)
        TvKind.ROKU, TvKind.LG, TvKind.SAMSUNG -> TvSupport.Remote
        TvKind.CHROMECAST -> TvSupport.NotYet
    }
}

/** One service announced on the network (NSD). The same TV often announces several; they're merged by address. */
data class TvSighting(val service: Service, val name: String, val host: String? = null, private val rawTxt: Map<String, String> = emptyMap()) {
    enum class Service(val type: String) { ANDROID_TV("_androidtvremote2._tcp"), CAST("_googlecast._tcp"), AIRPLAY("_airplay._tcp") }

    val txt: Map<String, String> = rawTxt.mapKeys { it.key.lowercase() }
    val id: String get() = service.type + "/" + name

    /** Android TVs; Cast devices with video out that aren't groups; AirPlay devices made by someone other than Apple. */
    val worthChecking: Boolean get() = when (service) {
        Service.ANDROID_TV -> true
        Service.CAST -> txt["ca"]?.toIntOrNull()?.let { it and 1 != 0 && it and 32 == 0 } ?: false
        Service.AIRPLAY -> txt["manufacturer"]?.let { it.isNotEmpty() && !it.lowercase().contains("apple") } ?: false
    }

    /** Cast service names are IDs; its TXT `fn` is the name people gave it. */
    val displayName: String get() = if (service == Service.CAST) txt["fn"]?.takeIf { it.isNotEmpty() } ?: name else name
}

/** A TV for the Connect screen; [support] is null while its ports are being checked. */
data class DiscoveredTv(val id: String, val name: String, val host: String?, val kind: TvKind = TvKind.ANDROID_TV, val support: TvSupport? = null)

object TvSightings {
    /** Every Android TV as soon as it's seen; other TVs once their ports say what they are; one row per address. */
    fun merge(sightings: List<TvSighting>, probes: Map<String, Set<Int>>): List<DiscoveredTv> {
        val rows = mutableListOf<DiscoveredTv>()
        val android = sightings.filter { it.service == TvSighting.Service.ANDROID_TV }
        val androidHosts = android.mapNotNull { it.host }.toSet()
        for (s in android) {
            rows += DiscoveredTv(s.id, s.name, s.host, TvKind.ANDROID_TV, s.host?.let { probes[it] }?.let { TvPorts.support(TvKind.ANDROID_TV, it) })
        }
        val others = sightings.filter { it.service != TvSighting.Service.ANDROID_TV && it.worthChecking && it.host != null && it.host !in androidHosts }
        for ((host, group) in others.groupBy { it.host!! }) {
            val open = probes[host] ?: continue
            val kind = TvPorts.kind(open) ?: continue
            val named = group.firstOrNull { it.service == TvSighting.Service.AIRPLAY } ?: group.minBy { it.name }
            rows += DiscoveredTv("host/$host", named.displayName, host, kind, TvPorts.support(kind, open))
        }
        return rows.sortedWith(compareBy<DiscoveredTv> { it.name.lowercase() }.thenBy { it.id })
    }
}

/**
 * Opens a TCP connection to each port and closes it as soon as it's accepted: no data is sent, so nothing shows
 * on the TV. A closed port refuses at once on a home network; a silent one gives up after [timeoutMs].
 */
object PortKnock {
    suspend fun openPorts(host: String, ports: List<Int> = TvPorts.ALL, timeoutMs: Int = 1500): Set<Int> = coroutineScope {
        ports.map { port -> async { if (isOpen(host, port, timeoutMs)) port else null } }.awaitAll().filterNotNull().toSet()
    }

    suspend fun isOpen(host: String, port: Int, timeoutMs: Int = 1500): Boolean = answer(host, port, timeoutMs) == Answer.OPEN

    /** How a port answered. Only [Answer.REFUSED] proves nothing listens there: a TV in standby or away is SILENT. */
    enum class Answer { OPEN, REFUSED, SILENT }

    suspend fun answer(host: String, port: Int, timeoutMs: Int = 1500): Answer = withContext(Dispatchers.IO) {
        try { Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }; Answer.OPEN }
        catch (e: java.net.ConnectException) { if (e.message?.contains("refused", ignoreCase = true) == true) Answer.REFUSED else Answer.SILENT }
        catch (e: Exception) { Answer.SILENT }
    }
}
