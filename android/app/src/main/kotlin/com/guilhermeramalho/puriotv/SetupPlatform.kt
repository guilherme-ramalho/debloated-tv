package com.guilhermeramalho.puriotv

import android.content.Context
import android.content.res.AssetManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.guilhermeramalho.puriotv.core.AdbClient
import com.guilhermeramalho.puriotv.core.AdbKeys
import com.guilhermeramalho.puriotv.core.AdbSigner
import com.guilhermeramalho.puriotv.core.DebloatProfile
import com.guilhermeramalho.puriotv.core.LauncherStep
import com.guilhermeramalho.puriotv.core.PlanNote
import com.guilhermeramalho.puriotv.core.ProfileSource
import com.guilhermeramalho.puriotv.core.RecoveryStore
import com.guilhermeramalho.puriotv.core.RemoteFailure
import com.guilhermeramalho.puriotv.core.RestoreReport
import com.guilhermeramalho.puriotv.core.SetupFailure
import com.guilhermeramalho.puriotv.core.SetupIssue
import com.guilhermeramalho.puriotv.core.SkipReason
import com.guilhermeramalho.puriotv.core.TVAddress
import com.guilhermeramalho.puriotv.core.TVConnector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.RSAPublicKey

/*
 * The Android side of TV setup: the ADB key in the Keystore, the bundled lists and TV Home, the recovery records and
 * a TVConnector. Everything that reaches a TV still goes through the core engine (Debloater, LauncherInstaller,
 * SetupSequence).
 */

/**
 * This install's ADB key (AdbKey.loadOrCreate on the iPhone): RSA-2048 in the Android Keystore, never leaving the
 * phone. adb signs the token as a SHA-1 digest, so the Keystore signs AdbKeys.digestInfo(token) with NONEwithRSA and
 * PKCS#1 padding. The TV remembers the public key once "Always allow" is ticked.
 */
class KeystoreAdbSigner private constructor(private val privateKey: PrivateKey, override val publicKey: RSAPublicKey) : AdbSigner {
    override fun sign(token: ByteArray): ByteArray = Signature.getInstance("NONEwithRSA").run {
        initSign(privateKey)
        update(AdbKeys.digestInfo(token))
        sign()
    }

    companion object {
        private const val ALIAS = "PurioTV.Adb.v1"
        @Volatile private var cached: KeystoreAdbSigner? = null

        /** Blocking (key generation takes a moment the first time): call it off the main thread. */
        @Synchronized
        fun loadOrCreate(): KeystoreAdbSigner {
            cached?.let { return it }
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val entry = store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry ?: run {
                val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_NONE)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                    .build()
                KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
                store.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
            }
            return KeystoreAdbSigner(entry.privateKey, entry.certificate.publicKey as RSAPublicKey).also { cached = it }
        }
    }
}

/** The bundled lists (assets/Profiles/<id>/), copied from ios/Resources/Profiles at build time. */
class AssetProfileSource(private val assets: AssetManager) : ProfileSource {
    override fun ids(): List<String> = (assets.list(ROOT) ?: emptyArray()).filter { safeId(it) }.sorted()
    override fun read(id: String, file: String): ByteArray? {
        if (!safeId(id) || !safeId(file)) return null
        return try { assets.open("$ROOT/$id/$file").use { it.readBytes() } } catch (e: java.io.IOException) { null }
    }

    companion object {
        private const val ROOT = "Profiles"
        /** A folder or file name, never a path (record files name their list, and they can come from elsewhere). */
        fun safeId(s: String) = s.isNotEmpty() && s != "." && s != ".." && s.all { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }
    }
}

object SetupPlatform {
    const val CLIENT_NAME = "Purio TV@Android"

    /** Where the recovery records live: app storage, as the iPhone's Application Support/TVRemote/recovery. */
    fun store(context: Context) = RecoveryStore(File(context.filesDir, "TVRemote/recovery"))

    /**
     * The lists setup can offer. Debug builds carry the development lists (assets exclude them in release); as on the
     * iPhone without its end-to-end flag, the development community lists are left out, so a Dev build on a real TV
     * is never offered them. Reads hundreds of small files: call it off the main thread.
     */
    fun loadProfiles(context: Context): List<DebloatProfile> =
        DebloatProfile.loadAll(AssetProfileSource(context.assets), includeDevelopment = BuildConfig.DEBUG)
            .filter { it.manifest.developmentOnly != true || !it.isCommunity }

    fun hasBundledApk(context: Context): Boolean = context.assets.list("Launcher")?.contains("tvhome.apk") == true

    suspend fun bundledApk(context: Context): ByteArray? = withContext(Dispatchers.IO) {
        try { context.assets.open("Launcher/tvhome.apk").use { it.readBytes() } } catch (e: java.io.IOException) { null }
    }

    /** Opens and authorizes an ADB connection; [onApproval] runs (on an IO thread) while the TV asks to allow this phone. */
    suspend fun open(target: TVAddress, approvalTimeoutMs: Long, onApproval: () -> Unit): AdbClient {
        val signer = withContext(Dispatchers.IO) { KeystoreAdbSigner.loadOrCreate() }
        val client = AdbClient(target.host, target.port, signer)
        try {
            client.connect(CLIENT_NAME, approvalTimeoutMs, onApproval)
        } catch (e: Throwable) {
            client.close()
            throw e
        }
        return client
    }

    /** New connections to the same TV with the approved key (the restart check, the Wi-Fi re-save, debugging off). */
    fun connector(target: TVAddress) = TVConnector { timeout, onApproval -> open(target, timeout, onApproval) }
}

// MARK: - Text for the engine's codes (never the engine's English)

fun SetupIssue.text(): Int = when (this) {
    SetupIssue.ADB_UNREACHABLE -> R.string.su_issue_adb_unreachable
    SetupIssue.ADB_REFUSED -> R.string.su_issue_adb_refused
    SetupIssue.ADB_BUSY -> R.string.su_issue_adb_busy
    SetupIssue.ADB_STREAM_REFUSED -> R.string.su_issue_adb_stream_refused
    SetupIssue.ADB_FILE_REFUSED -> R.string.su_issue_adb_file_refused
    SetupIssue.ADB_KEY_SIZE -> R.string.su_issue_adb_key_size
    SetupIssue.LIST_NOT_PACKAGES -> R.string.su_issue_list_not_packages
    SetupIssue.NO_APPS_LISTED -> R.string.su_issue_no_apps_listed
    SetupIssue.APPLY_UNCHECKED -> R.string.su_issue_apply_unchecked
    SetupIssue.RESTORE_OTHER_TV -> R.string.su_issue_restore_other_tv
    SetupIssue.RESTORE_UNCHECKED -> R.string.su_issue_restore_unchecked
    SetupIssue.HOME_CHOOSER_AMBIGUOUS -> R.string.su_issue_home_chooser_ambiguous
    SetupIssue.HOME_SETUP_WIZARD -> R.string.su_issue_home_setup_wizard
    SetupIssue.HOME_UNKNOWN -> R.string.su_issue_home_unknown
    SetupIssue.OLD_ANDROID -> R.string.su_issue_old_android
    SetupIssue.APK_DAMAGED -> R.string.su_issue_apk_damaged
    SetupIssue.INSTALL_OLDER_SDK -> R.string.su_issue_install_older_sdk
    SetupIssue.INSTALL_OTHER_KEY -> R.string.su_issue_install_other_key
    SetupIssue.INSTALL_DOWNGRADE -> R.string.su_issue_install_downgrade
    SetupIssue.INSTALL_REFUSED -> R.string.su_issue_install_refused
    SetupIssue.HOME_DID_NOT_START -> R.string.su_issue_home_did_not_start
    SetupIssue.HOME_STAYED -> R.string.su_issue_home_stayed
    SetupIssue.HOME_SWITCH_NO_ANSWER -> R.string.su_issue_home_switch_no_answer
    SetupIssue.HOME_WENT_ELSEWHERE -> R.string.su_issue_home_went_elsewhere
    SetupIssue.HELPERS_NOT_GRANTED -> R.string.su_issue_helpers_not_granted
    SetupIssue.SECURE_SETTINGS_KEPT -> R.string.su_issue_secure_settings_kept
    SetupIssue.INVALID_THEME -> R.string.su_issue_invalid_theme
    SetupIssue.THEME_REFUSED -> R.string.su_issue_theme_refused
    SetupIssue.NOT_CONNECTED -> R.string.su_issue_not_connected
    SetupIssue.INVALID_ADDRESS -> R.string.su_issue_invalid_address
    SetupIssue.NO_BUNDLED_HOME -> R.string.su_no_bundled_home
    SetupIssue.STOPPED_DURING_GROUP -> R.string.su_issue_stopped_during_group
    SetupIssue.WIFI_NOT_BACK -> R.string.su_issue_wifi_not_back
    SetupIssue.WIFI_NOT_SAVED -> R.string.su_issue_wifi_not_saved
    SetupIssue.DEBUGGING_UNREACHABLE -> R.string.su_issue_debugging_unreachable
    SetupIssue.UPDATE_HOME_NOT_OURS -> R.string.su_issue_update_home_not_ours
    SetupIssue.UPDATE_NO_PROFILE -> R.string.su_issue_update_no_profile
    SetupIssue.UPDATE_NOT_INSTALLED -> R.string.su_issue_update_not_installed
    SetupIssue.UPDATE_STILL_OLD -> R.string.su_issue_update_still_old
}

fun SkipReason.text(): Int = when (this) {
    SkipReason.NOT_A_PACKAGE -> R.string.su_skip_not_a_package
    SkipReason.CORE -> R.string.su_skip_core
    SkipReason.NEVER_DISABLE -> R.string.su_skip_never_disable
    SkipReason.WIFI_UNREADABLE -> R.string.su_skip_wifi_unreadable
    SkipReason.WIFI_ENTERPRISE -> R.string.su_skip_wifi_enterprise
    SkipReason.WIFI_NO_SHELL -> R.string.su_skip_wifi_no_shell
    SkipReason.HOME_OWNER_ALONE -> R.string.su_skip_home_owner_alone
    SkipReason.HOME_OWNER_WIZARD -> R.string.su_skip_home_owner_wizard
    SkipReason.HOME_NO_DEFAULT -> R.string.su_skip_home_no_default
    SkipReason.HOME_STOCK_UNKNOWN -> R.string.su_skip_home_stock_unknown
    SkipReason.INPUT_CHECK_HUNG -> R.string.su_skip_input_check_hung
    SkipReason.INPUT_CHECK_UNREADABLE -> R.string.su_skip_input_check_unreadable
    SkipReason.INPUT_DRIVER -> R.string.su_skip_input_driver
    SkipReason.OPENS_INPUTS -> R.string.su_skip_opens_inputs
    SkipReason.OPENS_SETTINGS -> R.string.su_skip_opens_settings
}

fun PlanNote.text(): Int = when (this) {
    PlanNote.HOME_BY_CLAIMS -> R.string.su_note_home_by_claims
    PlanNote.INPUTS_UNCHECKED -> R.string.su_note_inputs_unchecked
    PlanNote.INPUTS_SETTINGS_UNCHECKED -> R.string.su_note_inputs_settings_unchecked
    PlanNote.OPEN_DEBUGGING_PORT -> R.string.su_note_open_debugging_port
    PlanNote.CHROMECAST -> R.string.su_note_chromecast
}

fun LauncherStep.text(): Int = when (this) {
    LauncherStep.CHECKING -> R.string.su_ls_checking
    LauncherStep.PUSHING -> R.string.su_ls_pushing
    LauncherStep.INSTALLING -> R.string.su_ls_installing
    LauncherStep.STARTING -> R.string.su_ls_starting
    LauncherStep.HANDOVER -> R.string.su_ls_handover
    LauncherStep.HELPERS -> R.string.su_ls_helpers
    LauncherStep.THEME -> R.string.su_ls_theme
    LauncherStep.DONE -> R.string.su_ls_done
}

/** What to show for a failed setup step, in the person's language. */
fun setupErrorText(context: Context, e: Throwable): String = when (e) {
    is SetupFailure -> try {
        context.getString(e.issue.text(), *e.args.toTypedArray())
    } catch (x: java.util.IllegalFormatException) {
        e.message ?: context.getString(R.string.problem_other)
    }
    is UserMessage, is RemoteFailure -> errorText(context, e)
    is CancellationException -> context.getString(R.string.problem_other)
    else -> errorText(context, e)
}

/** What a restore's read-back says, for the setup flow and the Undo screen (RestoreText). */
fun restoreSummary(context: Context, report: RestoreReport): String {
    if (report.notBack.isNotEmpty())
        return context.getString(R.string.su_restore_not_back, report.notBack.size, report.notBack.joinToString(", "))
    val expected = report.expectedHome
    if (!report.homeOK && expected != null)
        return context.getString(R.string.su_restore_home, report.home.ifEmpty { context.getString(R.string.su_nothing) }, expected)
    return context.getString(R.string.su_restore_ok, report.keptOff.size)
}
