package com.guilhermeramalho.puriotv.core

import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPublicKey
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * The phone's TLS client identity for the TV's remote service: an RSA key and a self-signed certificate. On the
 * phone both live in the Android Keystore (app module, KeystoreIdentity); [Certificates.selfSigned] builds one in
 * plain JVM code for tests and tools.
 */
class ClientIdentity(val privateKey: PrivateKey, val certificate: X509Certificate) {
    val publicKey: PublicKey get() = certificate.publicKey

    companion object {
        /** The secret that proves the TV's six-character code: SHA-256 of both RSA keys and the code's last two bytes. */
        fun secret(code: String, client: PublicKey, server: PublicKey): ByteArray {
            val clean = code.trim().uppercase(Locale.ROOT)
            if (clean.length != 6) throw RemoteFailure(Problem.CODE_LENGTH)
            val bytes = (0 until 6 step 2).map {
                clean.substring(it, it + 2).toIntOrNull(16) ?: throw RemoteFailure(Problem.CODE_CHARACTERS)
            }
            val digest = sha256(components(client) + components(server) + byteArrayOf(bytes[1].toByte(), bytes[2].toByte()))
            if ((digest[0].toInt() and 255) != bytes[0]) throw RemoteFailure(Problem.CODE_MISMATCH)
            return digest
        }

        /** Modulus and exponent as unsigned big-endian bytes without leading zeros (ClientIdentity.components). */
        fun components(key: PublicKey): ByteArray {
            val rsa = key as? RSAPublicKey ?: throw RemoteFailure(Problem.IDENTITY_UNAVAILABLE, "Pairing requires RSA keys")
            return unsigned(rsa.modulus) + unsigned(rsa.publicExponent)
        }

        private fun unsigned(value: BigInteger): ByteArray {
            val bytes = value.toByteArray()
            var start = 0
            while (start < bytes.size - 1 && bytes[start] == 0.toByte()) start++
            return bytes.copyOfRange(start, bytes.size)
        }
    }
}

fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

/**
 * The name this install pairs under. The TV keeps one certificate per client name, so two phones pairing under the
 * same name sign each other out. Each install gets its own stable name ("Purio TV Android 3F2A"), saved by the app.
 */
object RemoteClientName {
    fun create(): String = "Purio TV Android " + UUID.randomUUID().toString().take(4).uppercase(Locale.ROOT)

    /** A certificate subject of its own per install: its pairing name plus a random part. */
    fun uniqueCommonName(name: String): String =
        name + " " + UUID.randomUUID().toString().replace("-", "").take(8).uppercase(Locale.ROOT)
}

/** Minimal DER writer for a self-signed X.509 v3 certificate (DER in Identity.swift). */
object Certificates {
    private fun item(tag: Int, content: ByteArray): ByteArray {
        val length = if (content.size < 128) byteArrayOf(content.size.toByte()) else {
            var count = content.size
            val encoded = ArrayList<Byte>()
            while (count > 0) { encoded.add(0, (count and 255).toByte()); count = count shr 8 }
            byteArrayOf((128 + encoded.size).toByte()) + encoded.toByteArray()
        }
        return byteArrayOf(tag.toByte()) + length + content
    }

    private fun sequence(data: ByteArray) = item(0x30, data)
    private fun integer(value: ByteArray): ByteArray {
        var bytes = value.dropWhile { it == 0.toByte() }.toByteArray()
        if (bytes.isEmpty()) bytes = byteArrayOf(0)
        if (bytes[0].toInt() and 128 != 0) bytes = byteArrayOf(0) + bytes
        return item(2, bytes)
    }

    private val sha256Rsa = sequence(byteArrayOf(0x06, 0x09, 0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(),
        0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00))

    fun selfSigned(keys: KeyPair, commonName: String = "Personal TV Remote", now: Date = Date()): X509Certificate {
        val name = sequence(item(0x31, sequence(byteArrayOf(0x06, 0x03, 0x55, 0x04, 0x03) +
            item(0x0c, commonName.toByteArray(Charsets.UTF_8)))))
        val format = SimpleDateFormat("yyyyMMddHHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val validity = sequence(item(0x18, format.format(Date(now.time - 86_400_000L)).toByteArray()) +
            item(0x18, format.format(Date(now.time + 10L * 365 * 86_400_000L)).toByteArray()))
        val serial = ByteArray(16).also { SecureRandom().nextBytes(it) }
        // keys.public.encoded is already a SubjectPublicKeyInfo.
        val body = sequence(item(0xa0, integer(byteArrayOf(2))) + integer(serial) + sha256Rsa + name + validity + name +
            keys.public.encoded)
        val signature = Signature.getInstance("SHA256withRSA").run {
            initSign(keys.private); update(body); sign()
        }
        val der = sequence(body + sha256Rsa + item(3, byteArrayOf(0) + signature))
        return CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
    }
}
