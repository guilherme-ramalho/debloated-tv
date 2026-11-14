package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.coroutineContext

/**
 * One short-lived paired connection per quick action, widget tap or tile tap (CommandRunner.swift). No queued
 * commands and no retries. Call it from the same single-thread scope its [TVSession] uses (the app's main thread).
 */
class CommandRunner(private val newSession: () -> TVSession, private val clock: () -> Long = System::currentTimeMillis) {
    private var session: TVSession? = null
    private var power: Boolean? = null
    private var muted: Boolean? = null
    private var waiter: CompletableDeferred<Unit>? = null
    private var waitForOn = false
    /** When the TV's remote started. Keys sent sooner are dropped on the TCL: the first key waits out [KEY_SETTLE]. */
    private var readyAt = 0L
    private var keysSettled = false

    fun cancel() {
        finish(RemoteFailure(Problem.INTERRUPTED, "Action cancelled"))
        session?.disconnect(); session = null
    }

    private fun finish(error: Throwable? = null) {
        val w = waiter ?: return
        waiter = null
        if (error == null) w.complete(Unit) else w.completeExceptionally(error)
    }

    private suspend fun wait(millis: Long, onOnly: Boolean = false, start: () -> Unit) {
        coroutineContext.ensureActive()
        waitForOn = onOnly
        val d = CompletableDeferred<Unit>()
        waiter = d
        start()
        try {
            withTimeout(millis) { d.await() }
        } catch (e: TimeoutCancellationException) {
            throw RemoteFailure(Problem.TIMED_OUT)
        } finally {
            if (waiter === d) waiter = null
        }
    }

    private fun open(): TVSession {
        val s = newSession()
        session = s
        power = null; muted = null; readyAt = 0; keysSettled = false
        s.onEvent = { event ->
            when (event) {
                is TVSession.Event.Power -> { power = event.on; if (!waitForOn || event.on) finish() }
                is TVSession.Event.Volume -> muted = event.muted
                is TVSession.Event.Error -> finish(RemoteFailure(event.problem, event.detail))
                else -> Unit
            }
        }
        return s
    }

    /** Runs [steps] in order; a failed step stops the sequence. [progress] gets the number of steps done. */
    suspend fun run(steps: List<ActionStep>, pin: ByteArray, apps: List<RemoteApp>, inputs: List<TVInput> = emptyList(), progress: ((Int) -> Unit)? = null) {
        if (steps.size !in 1..12) throw RemoteFailure(Problem.INVALID_ACTION)
        coroutineContext.ensureActive()
        val s = open()
        try {
            wait(15_000) { s.connect(pin) }
            readyAt = clock()
            var sentKey = false
            suspend fun key(k: TVKey) { settleKeys(); s.writeKey(k); sentKey = true }
            steps.forEachIndexed { index, step ->
                coroutineContext.ensureActive()
                when (step.kind) {
                    ActionStep.Kind.WAKE -> wakeIfOff(s)
                    ActionStep.Kind.SLEEP -> if (power == true) key(TVKey.POWER)
                    ActionStep.Kind.OPEN_APP -> {
                        val app = apps.firstOrNull { it.id == step.argument }
                        if (power != true || app == null) throw RemoteFailure(Problem.ACTION_APP_UNAVAILABLE)
                        s.writeLaunch(app.launchURL)
                    }
                    ActionStep.Kind.INPUT -> {
                        val input = inputs.firstOrNull { it.id == step.argument }
                        if (power != true || input == null) throw RemoteFailure(Problem.ACTION_INPUT_UNASSIGNED)
                        s.writeLaunch(input.launchURL)
                    }
                    ActionStep.Kind.HOME -> key(TVKey.HOME)
                    ActionStep.Kind.PAUSE -> key(TVKey.PAUSE)
                    ActionStep.Kind.PLAY_PAUSE -> key(TVKey.PLAY_PAUSE)
                    ActionStep.Kind.VOLUME_UP -> key(TVKey.VOLUME_UP)
                    ActionStep.Kind.VOLUME_DOWN -> key(TVKey.VOLUME_DOWN)
                    ActionStep.Kind.KEY -> {
                        val k = step.key ?: throw RemoteFailure(Problem.INVALID_ACTION)
                        // Power on a TV in standby wakes it the way Wake does; otherwise it's a plain key.
                        if (k == TVKey.POWER && power == false) wakeIfOff(s) else key(k)
                    }
                    ActionStep.Kind.MUTE -> {
                        if (muted == null) delay(300)
                        val m = muted ?: throw RemoteFailure(Problem.ACTION_MUTE_UNKNOWN)
                        if (!m) key(TVKey.MUTE)
                    }
                }
                progress?.invoke(index + 1)
                if (index < steps.size - 1) delay(350)
            }
            // Let the last key reach the TV's input before the connection closes.
            if (sentKey) delay(300)
        } finally {
            s.disconnect()
            if (session === s) session = null
        }
    }

    private suspend fun settleKeys() {
        if (keysSettled) return
        keysSettled = true
        val left = KEY_SETTLE - (clock() - readyAt)
        if (left > 0) delay(left)
    }

    /** Wakes a TV that reported it's off: let its remote input settle, press Power once, wait for it to report on. */
    private suspend fun wakeIfOff(s: TVSession) {
        if (power != false) return
        settleKeys()
        if (power != false) return
        s.writeKey(TVKey.POWER)
        if (power != true) wait(10_000, onOnly = true) {}
    }

    /** Connects with the saved pairing and waits for the TV's first report. Sends no command. */
    suspend fun diagnose(pin: ByteArray) {
        val s = open()
        try { wait(15_000) { s.connect(pin) } } finally { s.disconnect(); if (session === s) session = null }
    }

    companion object { const val KEY_SETTLE = 1500L }
}
