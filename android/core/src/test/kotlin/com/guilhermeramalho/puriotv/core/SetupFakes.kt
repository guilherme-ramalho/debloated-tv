package com.guilhermeramalho.puriotv.core

import java.io.File

/** Fakes for the setup engine tests (FakeTV, FakeDevice and ScriptedTV in ios/Tests). */

internal val profilesRoot = File("../../ios/Resources/Profiles")
internal val profileSource = DirectoryProfileSource(profilesRoot)

internal fun ok(output: String) = AdbClient.ShellResult(output, 0)

/** A scripted TV: the first matching prefix answers; everything sent is kept for assertions (DebloatTests.FakeTV). */
internal class FakeTV(private val enabledAtStart: Set<String>, private val answers: List<Pair<String, String>> = emptyList()) : TVShell {
    val sent = mutableListOf<String>()
    val disabledNow = mutableSetOf<String>()
    override suspend fun shell(command: String, timeoutMs: Long): AdbClient.ShellResult {
        sent += command
        if (command.startsWith("pm disable-user --user 0 ")) { disabledNow += command.substring(25); return ok("Package new state: disabled-user") }
        if (command == "pm list packages -e --user 0") return ok((enabledAtStart - disabledNow).sorted().joinToString("\n") { "package:$it" })
        for ((prefix, answer) in answers) if (command.startsWith(prefix)) return ok(answer)
        return ok("")
    }
}

/** A TV for installs: Home moves to [homeAfterHandover] once set-home-activity names the new launcher (LauncherInstallTests.FakeDevice). */
internal class FakeDevice(private val answers: List<Pair<String, String>>,
                          private val homeAfterHandover: String = "com.gathin.tvhome/.MainActivity") : TVDevice {
    val sent = mutableListOf<String>()
    val pushed = mutableMapOf<String, ByteArray>()
    /** What the WRITE_SECURE_SETTINGS step prints; null: the marker the step asked for, as a TV that did it. */
    var secureSettingsAnswer: String? = null
    private var handedOver = false
    override suspend fun push(data: ByteArray, path: String, mode: Int, progress: ((Double) -> Unit)?) { pushed[path] = data; progress?.invoke(1.0) }
    override suspend fun shell(command: String, timeoutMs: Long): AdbClient.ShellResult {
        sent += command
        if (command.startsWith("cmd package set-home-activity --user 0 com.gathin.tvhome")) handedOver = true
        if (command.startsWith(DebloatRules.HOME_QUERY)) return ok(if (handedOver) homeAfterHandover else "com.google.android.apps.tv.launcherx/.home.HomeActivity")
        if (command.contains("WRITE_SECURE_SETTINGS")) return ok(secureSettingsAnswer ?: if (command.startsWith("pm grant")) "restore-granted\n" else "secure-settings-revoked\n")
        val apk = pushed["/data/local/tmp/tvhome.apk"]
        if (command.startsWith("md5sum") && apk != null) return ok(LauncherInstaller.md5(apk) + "  /data/local/tmp/tvhome.apk")
        for ((prefix, answer) in answers) if (command.startsWith(prefix)) return ok(answer)
        return ok("")
    }
}

/** A TV that answers exact commands first, then prefixes, and can fail chosen commands (EngineEdgeTests.ScriptedTV). */
internal class ScriptedTV : TVDevice {
    val exact = mutableMapOf<String, String>()
    val prefixes = mutableListOf<Pair<String, String>>()
    val failing = mutableSetOf<String>()
    var md5Override: String? = null
    val sent = mutableListOf<String>()
    val pushed = mutableMapOf<String, ByteArray>()
    var closed = 0
    class Down : Exception()
    override suspend fun push(data: ByteArray, path: String, mode: Int, progress: ((Double) -> Unit)?) { pushed[path] = data }
    override suspend fun close() { closed++ }
    override suspend fun shell(command: String, timeoutMs: Long): AdbClient.ShellResult {
        sent += command
        if (command in failing) throw Down()
        val path = pushed.keys.firstOrNull()
        if (command.startsWith("md5sum") && path != null) return ok("${md5Override ?: LauncherInstaller.md5(pushed[path]!!)}  $path")
        exact[command]?.let { return ok(it) }
        for ((prefix, answer) in prefixes) if (command.startsWith(prefix)) return ok(answer)
        if (command.contains("WRITE_SECURE_SETTINGS")) return ok(if (command.startsWith("pm grant")) "restore-granted" else "secure-settings-revoked")
        return ok("")
    }
}

/** Runs [block] and returns the SetupFailure it threw (fails the test when it didn't). */
internal suspend fun failure(block: suspend () -> Unit): SetupFailure {
    try { block() } catch (e: SetupFailure) { return e }
    throw AssertionError("expected a SetupFailure")
}
