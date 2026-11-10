package com.guilhermeramalho.puriotv.core

import kotlin.math.abs
import kotlin.math.max

/** Android key codes the remote sends (TVKey in Wire.swift). */
enum class TVKey(val code: Long) {
    HOME(3), BACK(4), UP(19), DOWN(20), LEFT(21), RIGHT(22), SELECT(23),
    DELETE(67), VOLUME_UP(24), VOLUME_DOWN(25), POWER(26), PLAY_PAUSE(85), PLAY(126), PAUSE(127), MUTE(164),
    SETTINGS(176), INPUTS(178), REWIND(89), FAST_FORWARD(90), CAPTIONS(175);

    companion object {
        fun of(code: Long): TVKey? = entries.firstOrNull { it.code == code }

        /** Screen coordinates: right/down are positive. A short drag is not a swipe. */
        fun swipeDirection(dx: Double, dy: Double): TVKey? {
            if (!dx.isFinite() || !dy.isFinite() || max(abs(dx), abs(dy)) < 28) return null
            return if (abs(dx) > abs(dy)) (if (dx > 0) RIGHT else LEFT) else (if (dy > 0) DOWN else UP)
        }
    }
}

/** Only an explicit wake action may survive reconnection, once and for at most 30 seconds. */
class WakeRequest {
    private var deadline: Long? = null
    fun begin(nowMillis: Long = System.currentTimeMillis()) { deadline = nowMillis + 30_000 }
    fun cancel() { deadline = null }
    fun consume(powerIsOn: Boolean, nowMillis: Long = System.currentTimeMillis()): TVKey? {
        val until = deadline
        deadline = null
        return if (!powerIsOn && until != null && nowMillis < until) TVKey.POWER else null
    }
}

/**
 * Delays the first navigation command until a touch becomes a tap, hold or swipe. Crossing the swipe threshold
 * cancels the pending button so a swipe cannot also tap it (PadInteraction in Wire.swift).
 */
class PadInteraction {
    sealed interface Command {
        data class Tap(val key: TVKey) : Command
        data class Press(val key: TVKey) : Command
        data class Release(val key: TVKey) : Command
    }

    private sealed interface Phase {
        data object Idle : Phase
        data class Pending(val key: TVKey?) : Phase
        data class Holding(val key: TVKey) : Phase
        data object Swiping : Phase
    }

    private var phase: Phase = Phase.Idle
    val isSwiping get() = phase == Phase.Swiping

    fun begin(key: TVKey?): List<Command> = cancel().also { phase = Phase.Pending(key) }

    fun move(dx: Double, dy: Double): List<Command> {
        if (TVKey.swipeDirection(dx, dy) == null) return emptyList()
        return when (val p = phase) {
            is Phase.Holding -> { phase = Phase.Swiping; listOf(Command.Release(p.key)) }
            is Phase.Pending -> { phase = Phase.Swiping; emptyList() }
            else -> emptyList()
        }
    }

    fun hold(): List<Command> {
        val p = phase
        if (p !is Phase.Pending || p.key == null) return emptyList()
        phase = Phase.Holding(p.key)
        return listOf(Command.Press(p.key))
    }

    fun end(dx: Double, dy: Double): List<Command> {
        val p = phase
        phase = Phase.Idle
        return when (p) {
            is Phase.Pending -> TVKey.swipeDirection(dx, dy)?.let { listOf(Command.Tap(it)) }
                ?: p.key?.let { listOf(Command.Tap(it)) } ?: emptyList()
            is Phase.Holding -> listOf(Command.Release(p.key))
            Phase.Swiping -> TVKey.swipeDirection(dx, dy)?.let { listOf(Command.Tap(it)) } ?: emptyList()
            Phase.Idle -> emptyList()
        }
    }

    fun cancel(): List<Command> {
        val p = phase
        phase = Phase.Idle
        return if (p is Phase.Holding) listOf(Command.Release(p.key)) else emptyList()
    }
}
