package com.guilhermeramalho.puriotv.core

import kotlin.math.abs
import kotlin.math.max

/** Android key codes the remote sends (TVKey in Wire.swift). */
enum class TVKey(val code: Long) {
    HOME(3), BACK(4), UP(19), DOWN(20), LEFT(21), RIGHT(22), SELECT(23),
    DELETE(67), VOLUME_UP(24), VOLUME_DOWN(25), POWER(26), PLAY_PAUSE(85), PLAY(126), PAUSE(127), MUTE(164),
    SETTINGS(176), INPUTS(178), REWIND(89), FAST_FORWARD(90), CAPTIONS(175),
    /** 1.3: channels (Live TV, set-top boxes) and the number pad. */
    CHANNEL_UP(166), CHANNEL_DOWN(167),
    DIGIT_0(7), DIGIT_1(8), DIGIT_2(9), DIGIT_3(10), DIGIT_4(11), DIGIT_5(12), DIGIT_6(13), DIGIT_7(14), DIGIT_8(15), DIGIT_9(16);

    /** The digit a number-pad key types, or null. */
    val digit: Int? get() = DIGITS.indexOf(this).takeIf { it >= 0 }

    companion object {
        fun of(code: Long): TVKey? = entries.firstOrNull { it.code == code }
        /** 0 to 9, in order, for the number pad. */
        val DIGITS: List<TVKey> by lazy { listOf(DIGIT_0, DIGIT_1, DIGIT_2, DIGIT_3, DIGIT_4, DIGIT_5, DIGIT_6, DIGIT_7, DIGIT_8, DIGIT_9) }

        /**
         * Screen coordinates: right/down are positive. A short drag is not a swipe. [reversed] (the "Reverse swipe
         * direction" setting) moves the other way: swipe left to go right, up to go down.
         */
        fun swipeDirection(dx: Double, dy: Double, reversed: Boolean = false): TVKey? {
            if (!dx.isFinite() || !dy.isFinite() || max(abs(dx), abs(dy)) < 28) return null
            val x = if (reversed) -dx else dx
            val y = if (reversed) -dy else dy
            return if (abs(x) > abs(y)) (if (x > 0) RIGHT else LEFT) else (if (y > 0) DOWN else UP)
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
    /** Swipes go the other way (RemotePreferences.reverseSwipe). */
    var reversed = false

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
            is Phase.Pending -> TVKey.swipeDirection(dx, dy, reversed)?.let { listOf(Command.Tap(it)) }
                ?: p.key?.let { listOf(Command.Tap(it)) } ?: emptyList()
            is Phase.Holding -> listOf(Command.Release(p.key))
            Phase.Swiping -> TVKey.swipeDirection(dx, dy, reversed)?.let { listOf(Command.Tap(it)) } ?: emptyList()
            Phase.Idle -> emptyList()
        }
    }

    fun cancel(): List<Command> {
        val p = phase
        phase = Phase.Idle
        return if (p is Phase.Holding) listOf(Command.Release(p.key)) else emptyList()
    }
}
