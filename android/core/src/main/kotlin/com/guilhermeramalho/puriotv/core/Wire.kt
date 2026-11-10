package com.guilhermeramalho.puriotv.core

import java.io.ByteArrayOutputStream

/**
 * Why something failed, as a code the app turns into a translated sentence (strings.xml). The core module has no
 * Android resources, so it never builds user-facing text itself. Mirrors the messages in ios/Sources/Core.
 */
enum class Problem {
    INVALID_PROTOCOL, FRAME_LIMIT, CONNECT_FAILED, TIMED_OUT, CLOSED, INTERRUPTED, NOT_READY, IDENTITY_CHANGED,
    PAIRING_REJECTED_BY_TV, PAIRING_REFUSED, PAIRING_EXPIRED, HANDSHAKE_INCOMPLETE, NO_KEY_COMMANDS, COMMAND_REJECTED,
    NO_KEYBOARD, TEXT_LENGTH, INVALID_LINK, START_PAIRING_FIRST, CODE_LENGTH, CODE_CHARACTERS, CODE_MISMATCH,
    IDENTITY_UNAVAILABLE, EDITOR_NO_ANSWER, EDITOR_OLD, EDITOR_CLOSED, EDITOR_INVALID, EDITOR_TIMEOUT,
    EDITOR_NOT_CONNECTED, EDITOR_REJECTED, INVALID_LAYOUT,
}

class RemoteFailure(val problem: Problem, detail: String? = null) : Exception(detail ?: problem.name)

/** The small protobuf subset used by the Android TV Remote v2 protocol (Wire.swift). */
object Wire {
    class Field(val number: Int, val integer: Long?, val bytes: ByteArray?)

    fun varint(value: Long): ByteArray {
        val out = ByteArrayOutputStream()
        var v = value
        do {
            var byte = (v and 127).toInt()
            v = v ushr 7
            if (v != 0L) byte = byte or 128
            out.write(byte)
        } while (v != 0L)
        return out.toByteArray()
    }

    fun int(field: Int, value: Long): ByteArray = varint((field shl 3).toLong()) + varint(value)
    fun bytes(field: Int, value: ByteArray): ByteArray =
        varint((field shl 3 or 2).toLong()) + varint(value.size.toLong()) + value
    fun string(field: Int, value: String): ByteArray = bytes(field, value.toByteArray(Charsets.UTF_8))

    /** Reads one varint at [offset]; returns the value and the offset after it. Values are unsigned 64-bit. */
    fun readVarint(bytes: ByteArray, offset: Int): Pair<Long, Int> {
        var value = 0L
        var at = offset
        var shift = 0
        while (shift <= 63) {
            if (at >= bytes.size) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Incomplete protocol value")
            val byte = bytes[at].toInt() and 255
            at++
            if (shift == 63 && byte > 1) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Invalid protocol value")
            value = value or ((byte and 127).toLong() shl shift)
            if (byte and 128 == 0) return value to at
            shift += 7
        }
        throw RemoteFailure(Problem.INVALID_PROTOCOL, "Invalid protocol value")
    }

    fun fields(data: ByteArray): List<Field> {
        var offset = 0
        val result = ArrayList<Field>()
        while (offset < data.size) {
            val (tag, next) = readVarint(data, offset)
            offset = next
            val number = (tag ushr 3)
            if (number <= 0 || number > Int.MAX_VALUE) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Invalid protocol field")
            when ((tag and 7).toInt()) {
                0 -> {
                    val (value, after) = readVarint(data, offset)
                    offset = after
                    result += Field(number.toInt(), value, null)
                }
                2 -> {
                    val (length, after) = readVarint(data, offset)
                    offset = after
                    if (length < 0 || length > (data.size - offset).toLong())
                        throw RemoteFailure(Problem.INVALID_PROTOCOL, "Truncated protocol message")
                    val end = offset + length.toInt()
                    result += Field(number.toInt(), null, data.copyOfRange(offset, end))
                    offset = end
                }
                1, 5 -> {
                    val length = if ((tag and 7) == 1L) 8 else 4
                    if (length > data.size - offset) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Truncated protocol message")
                    offset += length
                }
                else -> throw RemoteFailure(Problem.INVALID_PROTOCOL, "Unsupported protocol field")
            }
        }
        return result
    }

    fun number(field: Int, data: ByteArray): Long = fields(data).firstOrNull { it.number == field }?.integer ?: 0L

    /** A message with its varint length prefix, ready for the socket. */
    fun frame(payload: ByteArray): ByteArray = varint(payload.size.toLong()) + payload
}

/** Handles split length prefixes, fragmented messages, and several messages in one TCP read (FrameDecoder in Swift). */
class FrameDecoder(maxFrameSize: Int = 65536) {
    private val maximum = maxFrameSize.coerceIn(1, 4_194_304)
    private var buffer = ByteArray(0)

    fun append(incoming: ByteArray): List<ByteArray> {
        if (buffer.size + incoming.size > maximum * 2 + 10) throw RemoteFailure(Problem.FRAME_LIMIT, "Protocol buffer limit exceeded")
        buffer += incoming
        val result = ArrayList<ByteArray>()
        while (buffer.isNotEmpty()) {
            val head = buffer.copyOfRange(0, minOf(5, buffer.size))
            val last = head.indexOfFirst { it.toInt() and 128 == 0 }
            if (last < 0) {
                if (head.size == 5) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Invalid frame length")
                break
            }
            val (size, _) = Wire.readVarint(head, 0)
            if (size <= 0 || size > maximum) throw RemoteFailure(Problem.INVALID_PROTOCOL, "Invalid frame size")
            val prefix = last + 1
            if (buffer.size < prefix + size.toInt()) break
            result += buffer.copyOfRange(prefix, prefix + size.toInt())
            buffer = buffer.copyOfRange(prefix + size.toInt(), buffer.size)
        }
        return result
    }
}
