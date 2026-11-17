package com.guilhermeramalho.puriotv

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.guilhermeramalho.puriotv.core.ClientIdentity
import com.guilhermeramalho.puriotv.core.DiscoveredTv
import com.guilhermeramalho.puriotv.core.PortKnock
import com.guilhermeramalho.puriotv.core.TvSighting
import com.guilhermeramalho.puriotv.core.TvSightings
import com.guilhermeramalho.puriotv.core.Problem
import com.guilhermeramalho.puriotv.core.RemoteClientName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.math.BigInteger
import java.net.Inet4Address
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import javax.security.auth.x500.X500Principal

/** Small saved state: this install's pairing name and the paired TV. The key itself stays in the Keystore. */
class Store(context: Context) {
    private val prefs = context.getSharedPreferences("remote", Context.MODE_PRIVATE)

    val clientName: String
        get() = prefs.getString("clientName", null) ?: RemoteClientName.create().also {
            prefs.edit().putString("clientName", it).apply()
        }

    /** [kind] is a TvKind name: Android TV unless Connect said Roku, LG or Samsung. */
    data class PairedTV(val host: String, val name: String, val pin: ByteArray?, val kind: String = "ANDROID_TV")

    var tv: PairedTV?
        get() {
            val host = prefs.getString("host", null) ?: return null
            val pin = prefs.getString("pin", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
            return PairedTV(host, prefs.getString("tvName", host) ?: host, pin, prefs.getString("tvKind", null) ?: "ANDROID_TV")
        }
        set(value) {
            prefs.edit().apply {
                if (value == null) { remove("host"); remove("tvName"); remove("pin"); remove("tvKind") } else {
                    putString("host", value.host); putString("tvName", value.name); putString("tvKind", value.kind)
                    if (value.pin == null) remove("pin") else putString("pin", Base64.encodeToString(value.pin, Base64.NO_WRAP))
                }
            }.apply()
        }
}

/**
 * The TLS client identity in the Android Keystore: a 2048-bit RSA key that never leaves the phone, with the
 * self-signed certificate the Keystore makes for it. Its subject is unique per install (the TV keeps one pairing
 * per subject), as on the iPhone.
 */
object KeystoreIdentity {
    // v3: v2 keys allowed signing only, and TLS 1.3 (RSA-PSS) failed in the handshake on a real TV.
    private const val ALIAS = "PurioTV.Client.v3"
    private const val OLD_ALIAS = "PurioTV.Client.v2"

    fun loadOrCreate(clientName: String): ClientIdentity {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry)?.let {
            return ClientIdentity(it.privateKey, it.certificate as X509Certificate)
        }
        if (store.containsAlias(OLD_ALIAS)) store.deleteEntry(OLD_ALIAS)
        val now = System.currentTimeMillis()
        // Conscrypt signs with a Keystore key through a callback: PKCS#1 v1.5 (TLS 1.2) as NONEwithRSA, but RSA-PSS
        // (TLS 1.3) as a raw private-key operation (RSA/ECB/NoPadding), which needs DECRYPT with no padding.
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(2048)
            .setCertificateSubject(X500Principal("CN=" + RemoteClientName.uniqueCommonName(clientName).replace(",", " ")))
            .setCertificateSerialNumber(BigInteger.valueOf(now))
            .setCertificateNotBefore(Date(now - 86_400_000L))
            .setCertificateNotAfter(Date(now + 10L * 365 * 86_400_000L))
            // TLS 1.2 signs with PKCS#1 v1.5, TLS 1.3 with PSS; Conscrypt may hand over a raw digest (NONE).
            .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
            .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE, KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
            .setRandomizedEncryptionRequired(false)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        val entry = store.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
        return ClientIdentity(entry.privateKey as PrivateKey, entry.certificate as X509Certificate)
    }
}

/**
 * Finds TVs on the Wi-Fi the way their own apps do (TVDiscovery.swift): Android TVs and Google TVs announce
 * `_androidtvremote2._tcp`, Chromecasts `_googlecast._tcp`, LG, Samsung, Roku and other TVs with AirPlay
 * `_airplay._tcp`. Each address is then knocked on (TvKind.kt) to tell what it is and what Purio can do there.
 * Runs only while the TV picker is on screen (start/stop), so nothing searches in the background.
 */
class TVDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val _tvs = MutableStateFlow<List<DiscoveredTv>>(emptyList())
    val tvs: StateFlow<List<DiscoveredTv>> = _tvs
    private var listeners: List<NsdManager.DiscoveryListener> = emptyList()
    private val sightings = mutableMapOf<String, TvSighting>()
    private val probes = mutableMapOf<String, Set<Int>>()
    private val probing = mutableMapOf<String, Job>()
    /** NSD resolves one service at a time before Android 14 (a second one fails with "already active"). */
    private val waiting = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun start() {
        stop()
        sightings.clear(); probes.clear(); _tvs.value = emptyList()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        listeners = TvSighting.Service.entries.map { service ->
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) = Unit
                override fun onDiscoveryStopped(serviceType: String) = Unit
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
                override fun onServiceFound(info: NsdServiceInfo) = main.post {
                    val sighting = TvSighting(service, info.serviceName)
                    if (sighting.id !in sightings) {
                        sightings[sighting.id] = sighting
                        // Other services are worth checking only after their TXT record is read, so all are resolved.
                        waiting.addLast(info); resolveNext()
                        publish()
                    }
                }.let { }
                override fun onServiceLost(info: NsdServiceInfo) = main.post {
                    sightings.remove(TvSighting(service, info.serviceName).id); publish()
                }.let { }
            }.also { nsd.discoverServices(service.type, NsdManager.PROTOCOL_DNS_SD, it) }
        }
    }

    fun stop() {
        listeners.forEach { runCatching { nsd.stopServiceDiscovery(it) } }
        listeners = emptyList()
        waiting.clear(); resolving = false
        scope.cancel(); probing.clear()
    }

    private fun publish() {
        val next = TvSightings.merge(sightings.values.toList(), probes)
        if (next != _tvs.value) _tvs.value = next
    }

    @Suppress("DEPRECATION") // resolveService is the API available back to Android 8; one at a time.
    private fun resolveNext() {
        if (resolving) return
        val info = waiting.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = main.post {
                resolving = false
                // A resolve left over from an earlier search can still be running: try this one again shortly.
                if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE && listeners.isNotEmpty()) {
                    waiting.addFirst(serviceInfo); main.postDelayed({ resolveNext() }, 300)
                } else resolveNext()
            }.let { }
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val address = (if (Build.VERSION.SDK_INT >= 34) resolved.hostAddresses else listOfNotNull(resolved.host))
                    .firstOrNull { it is Inet4Address }?.hostAddress
                val txt = resolved.attributes.mapValues { (_, v) -> v?.toString(Charsets.UTF_8).orEmpty() }
                main.post {
                    resolving = false
                    val service = TvSighting.Service.entries.firstOrNull { resolved.serviceType.trim('.').startsWith(it.type) }
                        ?: TvSighting.Service.entries.firstOrNull { s -> sightings.containsKey(s.type + "/" + resolved.serviceName) }
                    val id = service?.let { it.type + "/" + resolved.serviceName }
                    if (id != null && address != null && sightings.containsKey(id)) {
                        val sighting = TvSighting(service, resolved.serviceName, address, txt)
                        sightings[id] = sighting
                        if (sighting.worthChecking) knock(address)
                        publish()
                    }
                    resolveNext()
                }
            }
        })
    }

    /** Once per address while searching. */
    private fun knock(host: String) {
        if (host in probes || host in probing) return
        probing[host] = scope.launch {
            probes[host] = PortKnock.openPorts(host)
            probing.remove(host)
            publish()
        }
    }
}

fun Problem.message(): Int = when (this) {
    Problem.INVALID_PROTOCOL, Problem.FRAME_LIMIT -> R.string.problem_invalid_protocol
    Problem.CONNECT_FAILED -> R.string.problem_connect_failed
    Problem.TIMED_OUT -> R.string.problem_timed_out
    Problem.CLOSED -> R.string.problem_closed
    Problem.INTERRUPTED -> R.string.problem_interrupted
    Problem.NOT_READY -> R.string.problem_not_ready
    Problem.IDENTITY_CHANGED -> R.string.problem_identity_changed
    Problem.PAIRING_REJECTED_BY_TV -> R.string.problem_pairing_rejected_by_tv
    Problem.PAIRING_REFUSED -> R.string.problem_pairing_refused
    Problem.PAIRING_EXPIRED -> R.string.problem_pairing_expired
    Problem.HANDSHAKE_INCOMPLETE -> R.string.problem_handshake_incomplete
    Problem.NO_KEY_COMMANDS -> R.string.problem_no_key_commands
    Problem.COMMAND_REJECTED -> R.string.problem_command_rejected
    Problem.NO_KEYBOARD -> R.string.problem_no_keyboard
    Problem.TEXT_LENGTH -> R.string.problem_text_length
    Problem.INVALID_LINK -> R.string.problem_invalid_link
    Problem.START_PAIRING_FIRST -> R.string.problem_start_pairing_first
    Problem.CODE_LENGTH -> R.string.problem_code_length
    Problem.CODE_CHARACTERS -> R.string.problem_code_characters
    Problem.CODE_MISMATCH -> R.string.problem_code_mismatch
    Problem.IDENTITY_UNAVAILABLE -> R.string.problem_identity_unavailable
    Problem.EDITOR_NO_ANSWER, Problem.EDITOR_OLD, Problem.EDITOR_CLOSED, Problem.EDITOR_INVALID, Problem.EDITOR_TIMEOUT,
    Problem.EDITOR_NOT_CONNECTED, Problem.EDITOR_REJECTED -> R.string.problem_editor
    Problem.INVALID_LAYOUT -> R.string.problem_other
    Problem.INVALID_ACTION -> R.string.problem_invalid_action
    Problem.INVALID_BACKUP -> R.string.problem_invalid_backup
    Problem.INVALID_PREFERENCES -> R.string.problem_invalid_preferences
    Problem.NOT_PAIRED -> R.string.problem_not_paired
    Problem.ACTION_APP_UNAVAILABLE -> R.string.problem_action_app
    Problem.ACTION_INPUT_UNASSIGNED -> R.string.problem_action_input
    Problem.ACTION_MUTE_UNKNOWN -> R.string.problem_action_mute
    Problem.CAST_LAUNCH_FAILED -> R.string.problem_cast_launch
    Problem.CAST_NO_CHROMECAST -> R.string.problem_cast_no_chromecast
    Problem.CAST_UNREACHABLE -> R.string.problem_cast_unreachable
    Problem.CAST_INTERRUPTED -> R.string.problem_cast_interrupted
    Problem.PHOTO_UNREADABLE -> R.string.problem_photo_unreadable
    Problem.VIDEO_UNREADABLE -> R.string.problem_video_unreadable
    Problem.NOT_ON_TV_WIFI -> R.string.problem_not_on_tv_wifi
    Problem.ROKU_LIMITED -> R.string.problem_roku_limited
    Problem.LG_REFUSED -> R.string.problem_lg_refused
    Problem.SAMSUNG_REFUSED -> R.string.problem_samsung_refused
    Problem.SAMSUNG_ALLOW_TIMEOUT -> R.string.problem_samsung_timeout
    Problem.ALLOW_ON_TV_FIRST -> R.string.problem_allow_first
    Problem.INPUTS_NEED_HOME -> R.string.problem_inputs_need_home
    Problem.TURN_ON_WITH_REMOTE -> R.string.problem_turn_on_with_remote
}

/** Where the TV setup status lives (the iPhone keeps it in UserDefaults). */
class PrefsSetupStore(context: Context) : com.guilhermeramalho.puriotv.core.SetupStatusStore {
    private val prefs = context.getSharedPreferences("setup", Context.MODE_PRIVATE)
    override fun load(): String? = prefs.getString("tvSetupStatus.v1", null)
    override fun save(json: String) { prefs.edit().putString("tvSetupStatus.v1", json).apply() }
}
