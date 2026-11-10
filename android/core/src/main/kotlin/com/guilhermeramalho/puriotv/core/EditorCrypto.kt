package com.guilhermeramalho.puriotv.core

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** RFC 5869 HKDF-SHA256 (EditorCrypto.hkdf in the launcher). */
fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
    require(length in 1..255 * 32)
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
    val prk = mac.doFinal(ikm)
    mac.init(SecretKeySpec(prk, "HmacSHA256"))
    val out = ByteArray(length)
    var t = ByteArray(0)
    var filled = 0
    var i = 1
    while (filled < length) {
        mac.update(t); mac.update(info); mac.update(i.toByte())
        t = mac.doFinal()
        val n = minOf(t.size, length - filled)
        System.arraycopy(t, 0, out, filled, n)
        filled += n; i++
    }
    return out
}

/**
 * The phone editor link (docs/launcher-editor-contract.md, version 2). A fresh 32-byte key travels to the TV inside
 * tvhome://phone-edit?k=…, sent through the already paired remote connection, so the editor needs no pairing of its own.
 */
object EditorLink {
    private val random = SecureRandom()
    fun random(count: Int) = ByteArray(count).also { random.nextBytes(it) }
    fun newKey() = random(32)
    /** Names a key without revealing it (HKDF-SHA256, 8 bytes); a TV listener for an older link turns it away. */
    fun keyId(key: ByteArray) = hkdf(key, ByteArray(0), "tvhome-editor v2 key-id".toByteArray(), 8)
    fun url(key: ByteArray) = "tvhome://phone-edit?k=" + Base64.getUrlEncoder().withoutPadding().encodeToString(key)
}

/** One direction of an editor session: AES-256-GCM with an HKDF-SHA256 key and an in-order counter nonce. */
class EditorCipher(sessionKey: ByteArray, phoneNonce: ByteArray, tvNonce: ByteArray, info: String) {
    internal val key: ByteArray
    private var counter = 0L

    init {
        if (sessionKey.size != 32 || phoneNonce.size != 16 || tvNonce.size != 16) throw RemoteFailure(Problem.EDITOR_INVALID, "Invalid TV editor key")
        key = hkdf(sessionKey, phoneNonce + tvNonce, info.toByteArray(), 32)
    }

    fun seal(plain: ByteArray): ByteArray {
        val nonce = nonce(counter)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        counter++
        return nonce + cipher.doFinal(plain)
    }

    fun open(frame: ByteArray): ByteArray {
        if (frame.size < 28 || !frame.copyOfRange(0, 12).contentEquals(nonce(counter)))
            throw RemoteFailure(Problem.EDITOR_INVALID, "TV editor message out of order")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, frame, 0, 12))
        val plain = try { cipher.doFinal(frame, 12, frame.size - 12) } catch (e: Exception) {
            throw RemoteFailure(Problem.EDITOR_INVALID, "TV editor message failed to open")
        }
        counter++
        return plain
    }

    companion object {
        const val PHONE_TO_TV = "tvhome-editor v2 phone-to-tv"
        const val TV_TO_PHONE = "tvhome-editor v2 tv-to-phone"
        fun nonce(counter: Long): ByteArray = ByteArray(4) + ByteBuffer.allocate(8).putLong(counter).array()
    }
}
